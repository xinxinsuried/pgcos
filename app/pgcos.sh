#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:-/config}"
CONFIG_FILE="${CONFIG_FILE:-$CONFIG_DIR/config.env}"
RCLONE_CONFIG="${RCLONE_CONFIG:-$CONFIG_DIR/rclone.conf}"
WORK_DIR="${WORK_DIR:-/tmp/pgcos}"

log() { printf "[%s] %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$*"; }
fail() { echo "Error: $*" >&2; exit 1; }

gum_input() {
  gum input --prompt "> " "$@"
}

gum_input_password() {
  gum input --password --prompt "> " "$@"
}

prompt_flow_pg_image() {
  local default_image="$1"
  local input=""
  if command -v gum >/dev/null 2>&1; then
    input="$(gum_input --value "${default_image}" --placeholder "Flow 使用的 PG 镜像（例如 postgres:17-alpine）")"
  else
    echo "Flow 使用的 PG 镜像 [${default_image}]:"
    read -r input
  fi
  [[ -z "$input" ]] && input="$default_image"
  echo "$input"
}

list_backups_pretty() {
  local instance_id="$1"
  local backups="${2:-}"
  if [[ -z "$backups" ]]; then
    backups="$(list_backups_for_instance "$instance_id" | sort)"
  fi
  [[ -z "$backups" ]] && { log "No backups"; return 0; }

  local rows=()
  local idx=1
  while read -r b; do
    [[ -z "$b" ]] && continue
    local ts
    ts="${b/_/ }"
    local epoch
    epoch="$(date -d "$ts" +%s 2>/dev/null || echo "")"
    local age="unknown"
    if [[ -n "$epoch" ]]; then
      local now
      now="$(date +%s)"
      local diff=$((now - epoch))
      local days=$((diff / 86400))
      local hours=$(((diff % 86400) / 3600))
      age="${days}d ${hours}h"
    fi
    local size_bytes
    local db_count
    size_bytes="$(rclone cat "cos:${COS_BUCKET}/${COS_PREFIX}/${instance_id}/${b}/metadata.json" --config "$RCLONE_CONFIG" 2>/dev/null | awk -F: '/total_bytes/ {gsub(/[^0-9]/,"",$2); print $2}')"
    db_count="$(rclone cat "cos:${COS_BUCKET}/${COS_PREFIX}/${instance_id}/${b}/metadata.json" --config "$RCLONE_CONFIG" 2>/dev/null | awk -F: '/db_count/ {gsub(/[^0-9]/,"",$2); print $2}')"
    if [[ -z "$size_bytes" ]]; then
      size_bytes="$(rclone lsjson "cos:${COS_BUCKET}/${COS_PREFIX}/${instance_id}/${b}" --config "$RCLONE_CONFIG" 2>/dev/null | awk -F: '/"Size"/ {sum+=$2} END {print sum+0}')"
    fi
    local size_human="${size_bytes}B"
    if [[ -n "$size_bytes" && "$size_bytes" =~ ^[0-9]+$ ]]; then
      size_human="$(numfmt --to=iec --suffix=B "$size_bytes" 2>/dev/null || echo "${size_bytes}B")"
    fi
    rows+=("$idx" "$b" "$ts" "$age" "$size_human" "${db_count:-?}")
    idx=$((idx + 1))
  done <<< "$backups"

  printf "%-4s %-22s %-19s %-10s %-10s %-8s\n" "#" "backup_id" "datetime" "age" "size" "dbs"
  printf "%-4s %-22s %-19s %-10s %-10s %-8s\n" "--" "----------------------" "-------------------" "----------" "----------" "--------"
  local i=0
  while [[ $i -lt ${#rows[@]} ]]; do
    printf "%-4s %-22s %-19s %-10s %-10s %-8s\n" "${rows[$i]}" "${rows[$((i+1))]}" "${rows[$((i+2))]}" "${rows[$((i+3))]}" "${rows[$((i+4))]}" "${rows[$((i+5))]}"
    i=$((i+6))
  done
}

prompt_backup_pick() {
  local backups="$1"
  mapfile -t _backup_arr <<< "$backups"
  local count="${#_backup_arr[@]}"
  [[ "$count" -eq 0 ]] && return 0

  echo ""
  echo "Select backup (number or backup_id). Press Enter for latest:"
  local input
  read -r input
  if [[ -z "$input" ]]; then
    echo "${_backup_arr[$((count - 1))]}"
    return 0
  fi
  if [[ "$input" =~ ^[0-9]+$ ]]; then
    local idx=$((input - 1))
    if [[ "$idx" -ge 0 && "$idx" -lt "$count" ]]; then
      echo "${_backup_arr[$idx]}"
      return 0
    fi
  fi
  echo "$input"
}

show_backup_details() {
  local instance_id="$1"
  local backup_id="$2"
  [[ -n "$backup_id" ]] || return 0

  local meta
  meta="$(rclone cat "cos:${COS_BUCKET}/${COS_PREFIX}/${instance_id}/${backup_id}/metadata.json" --config "$RCLONE_CONFIG" 2>/dev/null || true)"
  if [[ -z "$meta" ]]; then
    log "metadata.json not found for ${backup_id}"
    return 0
  fi

  echo ""
  echo "Details for: ${backup_id}"
  echo "-------------------------"
  echo "$meta" | awk -F: '/instance_id|timestamp|db_count|total_bytes/ {gsub(/[",]/,"",$2); gsub(/[ \t]+/,"",$2); print $1": "$2}'
  echo "Databases:"
  echo "$meta" | awk '/"databases"/ {flag=1; next} flag && /\]/ {flag=0} flag {gsub(/[", ]/,"",$0); if($0!="") print "  - "$0}'
  echo "DB sizes (bytes):"
  echo "$meta" | awk '/"db_sizes"/ {flag=1; next} flag && /}/ {flag=0} flag {gsub(/[",]/,"",$0); gsub(/^[ \t]+/,"",$0); if($0!="") print "  - "$0}'
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing command: $1"
}

ensure_dirs() {
  mkdir -p "$CONFIG_DIR" "$WORK_DIR"
}

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  fi
}

escape_value() {
  printf "%s" "$1" | sed "s/'/'\"'\"'/g"
}

save_config() {
  ensure_dirs
  cat > "$CONFIG_FILE" <<EOF
PG_INSTANCE_ID='$(escape_value "${PG_INSTANCE_ID}")'
PG_CONTAINER='$(escape_value "${PG_CONTAINER}")'
PG_USER='$(escape_value "${PG_USER}")'
PG_PASSWORD='$(escape_value "${PG_PASSWORD}")'
COS_BUCKET='$(escape_value "${COS_BUCKET}")'
COS_ENDPOINT='$(escape_value "${COS_ENDPOINT}")'
COS_SECRET_ID='$(escape_value "${COS_SECRET_ID}")'
COS_SECRET_KEY='$(escape_value "${COS_SECRET_KEY}")'
COS_PREFIX='$(escape_value "${COS_PREFIX}")'
SCHEDULE_CRON='$(escape_value "${SCHEDULE_CRON}")'
RETENTION_DAYS='$(escape_value "${RETENTION_DAYS}")'
RETENTION_COUNT='$(escape_value "${RETENTION_COUNT}")'
EOF
  chmod 600 "$CONFIG_FILE"

  cat > "$RCLONE_CONFIG" <<EOF
[cos]
type = s3
provider = TencentCOS
access_key_id = ${COS_SECRET_ID}
secret_access_key = ${COS_SECRET_KEY}
endpoint = ${COS_ENDPOINT}
acl = private
EOF
  chmod 600 "$RCLONE_CONFIG"
}

require_config() {
  [[ -f "$CONFIG_FILE" ]] || fail "Config not found. Run panel configure first."
}

pg_exec() {
  local cmd=(docker exec -e PGPASSWORD="${PG_PASSWORD}" -i "${PG_CONTAINER}")
  "${cmd[@]}" "$@"
}

list_pg_databases() {
  pg_exec psql -X -U "$PG_USER" -d postgres -A -t -c "select datname from pg_database where datistemplate=false order by 1" | sed 's/\r$//'
}

check_pg() {
  docker inspect "$PG_CONTAINER" >/dev/null 2>&1 || fail "Postgres container not found: $PG_CONTAINER"
  pg_exec psql -U "$PG_USER" -d postgres -c "select 1" >/dev/null
}

check_cos() {
  require_cmd rclone
  rclone lsd "cos:${COS_BUCKET}/${COS_PREFIX}" --config "$RCLONE_CONFIG" >/dev/null
}

backup_now() {
  require_config
  load_config
  ensure_dirs
  check_pg
  check_cos
  [[ -n "${PG_INSTANCE_ID:-}" ]] || fail "PG_INSTANCE_ID is required. Run configure first."

  local ts
  ts="$(date +'%Y-%m-%d_%H-%M-%S')"
  local dir="$WORK_DIR/$ts"
  mkdir -p "$dir"

  log "Dumping globals"
  pg_exec pg_dumpall -U "$PG_USER" --globals-only > "$dir/globals.sql"
  zstd -T0 -19 "$dir/globals.sql" -o "$dir/globals.sql.zst"
  rm -f "$dir/globals.sql"
  sha256sum "$dir/globals.sql.zst" > "$dir/globals.sql.zst.sha256"

  log "Dumping databases"
  local db
  local dbs=()
  local db_sizes=()
  mapfile -t dbs < <(list_pg_databases)
  log "Found ${#dbs[@]} databases"
  for db in "${dbs[@]}"; do
    [[ -z "$db" ]] && continue
    log "Dumping $db"
    pg_exec pg_dump -U "$PG_USER" -Fc "$db" > "$dir/$db.dump"
    zstd -T0 -19 "$dir/$db.dump" -o "$dir/$db.dump.zst"
    rm -f "$dir/$db.dump"
    sha256sum "$dir/$db.dump.zst" > "$dir/$db.dump.zst.sha256"
    db_sizes+=("$(stat -c %s "$dir/$db.dump.zst" 2>/dev/null || echo 0)")
  done

  log "Writing metadata"
  local total_bytes
  total_bytes="$(du -sb "$dir" | awk '{print $1}')"
  {
    echo '{'
    echo "  \"instance_id\": \"${PG_INSTANCE_ID}\"," 
    echo "  \"timestamp\": \"${ts}\"," 
    echo "  \"db_count\": ${#dbs[@]},"
    echo "  \"databases\": ["
    local i
    for i in "${!dbs[@]}"; do
      local comma=","
      [[ $i -eq $((${#dbs[@]} - 1)) ]] && comma=""
      echo "    \"${dbs[$i]}\"${comma}"
    done
    echo "  ],"
    echo "  \"db_sizes\": {"
    for i in "${!dbs[@]}"; do
      local comma=","
      [[ $i -eq $((${#dbs[@]} - 1)) ]] && comma=""
      echo "    \"${dbs[$i]}\": ${db_sizes[$i]}${comma}"
    done
    echo "  },"
    echo "  \"total_bytes\": ${total_bytes}"
    echo '}'
  } > "$dir/metadata.json"

  log "Uploading to COS"
  rclone copy "$dir" "cos:${COS_BUCKET}/${COS_PREFIX}/${PG_INSTANCE_ID}/${ts}" --config "$RCLONE_CONFIG"
  rm -rf "$dir"
  log "Backup complete: ${ts}"
}

update_self() {
  local image
  image="${PGCOS_IMAGE:-ghcr.io/xinxinsuried/pgcos:latest}"
  require_cmd docker
  log "Pulling image ${image}"
  docker pull "$image"
  log "Update complete. Restart services to apply the new image."
}

test_restore() {
  require_config
  load_config
  require_cmd docker

  local test_image
  test_image="${PG_TEST_IMAGE:-postgres:18.1-alpine}"
  local test_password
  test_password="${PG_TEST_PASSWORD:-pgcos_test_password}"
  local name
  name="pgcos-restore-test-$(date +%Y%m%d%H%M%S)"

  log "Starting test Postgres container: ${name}"
  docker run -d --name "$name" -e POSTGRES_PASSWORD="$test_password" "$test_image" >/dev/null

  log "Waiting for Postgres ready"
  local i
  for i in {1..30}; do
    if docker exec -e PGPASSWORD="$test_password" "$name" pg_isready -U postgres >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  local backup_id
  local instance_id
  instance_id="${PG_INSTANCE_ID}"
  [[ -n "$instance_id" ]] || instance_id="$(select_instance)"
  backup_id="$(latest_backup "$instance_id")"
  [[ -n "$backup_id" ]] || fail "No backup found for instance ${instance_id}"

  log "Restoring backup ${backup_id} into ${name}"
  PGCOS_OVERRIDE_PG_CONTAINER="$name" \
    PGCOS_OVERRIDE_PG_USER="postgres" \
    PGCOS_OVERRIDE_PG_PASSWORD="$test_password" \
    restore_from "$instance_id" "$backup_id"

  log "Test restore complete. Container still running: ${name}"
  log "Cleanup when done: docker rm -f ${name}"
}

test_flow() {
  require_config
  load_config
  require_cmd docker

  log "Running backup-now"
  backup_now

  local test_image
  test_image="${PG_TEST_IMAGE:-postgres:18.1-alpine}"
  test_image="$(prompt_flow_pg_image "$test_image")"
  local test_password
  test_password="${PG_TEST_PASSWORD:-pgcos_test_password}"
  local name
  name="pgcos-test-flow-$(date +%Y%m%d%H%M%S)"

  log "Starting test Postgres container: ${name}"
  docker run -d --name "$name" -e POSTGRES_PASSWORD="$test_password" "$test_image" >/dev/null

  local cleanup
  cleanup() {
    docker rm -f "$name" >/dev/null 2>&1 || true
  }
  trap cleanup EXIT

  log "Waiting for Postgres ready"
  local i
  for i in {1..30}; do
    if docker exec -e PGPASSWORD="$test_password" "$name" pg_isready -U postgres >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  local instance_id
  local backup_id
  instance_id="${PG_INSTANCE_ID}"
  [[ -n "$instance_id" ]] || instance_id="$(select_instance)"
  backup_id="$(latest_backup "$instance_id")"
  [[ -n "$backup_id" ]] || fail "No backup found for instance ${instance_id}"

  log "Restoring backup ${backup_id} into ${name}"
  PGCOS_OVERRIDE_PG_CONTAINER="$name" \
    PGCOS_OVERRIDE_PG_USER="postgres" \
    PGCOS_OVERRIDE_PG_PASSWORD="$test_password" \
    restore_from "$instance_id" "$backup_id"

  log "Verifying restore"
  local meta_db_count
  meta_db_count="$(rclone cat "cos:${COS_BUCKET}/${COS_PREFIX}/${instance_id}/${backup_id}/metadata.json" --config "$RCLONE_CONFIG" 2>/dev/null | awk -F: '/db_count/ {gsub(/[^0-9]/,"",$2); print $2}')"
  local restored_count
  restored_count="$(docker exec -e PGPASSWORD="$test_password" "$name" psql -U postgres -t -A -c "select count(*) from pg_database where datistemplate=false" postgres | tr -d '\r' | tr -d ' ')"
  if [[ -n "$meta_db_count" && -n "$restored_count" && "$restored_count" -ge "$meta_db_count" ]]; then
    log "Test flow OK: restored_count=${restored_count}, expected>=${meta_db_count}"
  else
    fail "Test flow failed: restored_count=${restored_count}, expected>=${meta_db_count}"
  fi

  log "Cleaning up test container"
  cleanup
  trap - EXIT
}

list_instances() {
  require_config
  load_config
  require_cmd rclone
  rclone lsd "cos:${COS_BUCKET}/${COS_PREFIX}" --config "$RCLONE_CONFIG" | awk '{print $5}'
}

list_backups_for_instance() {
  local instance_id="$1"
  require_config
  load_config
  require_cmd rclone
  rclone lsd "cos:${COS_BUCKET}/${COS_PREFIX}/${instance_id}" --config "$RCLONE_CONFIG" | awk '{print $5}'
}

select_instance() {
  local choice
  choice="$(list_instances | sort | gum choose --header "Select instance")" || true
  echo "$choice"
}

select_backup() {
  local instance_id="$1"
  local choice
  choice="$(list_backups_for_instance "$instance_id" | sort | tail -n 20 | gum choose --header "Select backup")" || true
  echo "$choice"
}

latest_backup() {
  local instance_id="$1"
  list_backups_for_instance "$instance_id" | sort | tail -n 1
}

restore_from() {
  local instance_id="$1"
  local backup_id="$2"
  [[ -n "$instance_id" ]] || fail "Instance id required"
  [[ -n "$backup_id" ]] || fail "Backup id required"
  require_config
  load_config
  if [[ -n "${PGCOS_OVERRIDE_PG_CONTAINER:-}" ]]; then
    PG_CONTAINER="$PGCOS_OVERRIDE_PG_CONTAINER"
  fi
  if [[ -n "${PGCOS_OVERRIDE_PG_USER:-}" ]]; then
    PG_USER="$PGCOS_OVERRIDE_PG_USER"
  fi
  if [[ -n "${PGCOS_OVERRIDE_PG_PASSWORD:-}" ]]; then
    PG_PASSWORD="$PGCOS_OVERRIDE_PG_PASSWORD"
  fi
  ensure_dirs
  check_pg
  check_cos

  local dir="$WORK_DIR/restore-$backup_id"
  rm -rf "$dir"
  mkdir -p "$dir"

  log "Downloading ${backup_id}"
  rclone copy "cos:${COS_BUCKET}/${COS_PREFIX}/${instance_id}/${backup_id}" "$dir" --config "$RCLONE_CONFIG"

  log "Restoring globals"
  zstd -d "$dir/globals.sql.zst" -o "$dir/globals.sql"
  pg_exec psql -U "$PG_USER" -d postgres < "$dir/globals.sql"

  log "Restoring databases"
  local dump
  for dump in "$dir"/*.dump.zst; do
    [[ -e "$dump" ]] || continue
    local db
    db="$(basename "$dump" .dump.zst)"
    local exists
    exists="$(pg_exec psql -U "$PG_USER" -t -A -c "select 1 from pg_database where datname='${db}'" postgres || true)"
    if [[ -z "$exists" ]]; then
      log "Creating database $db"
      pg_exec createdb -U "$PG_USER" "$db"
    fi
    log "Restoring $db"
    zstd -d -c "$dump" | pg_exec pg_restore -U "$PG_USER" --clean --if-exists -d "$db" -F c
  done

  rm -rf "$dir"
  log "Restore complete: ${backup_id}"
}

prune_backups() {
  require_config
  load_config
  require_cmd rclone

  local instance_id
  instance_id="${PG_INSTANCE_ID}"
  [[ -n "$instance_id" ]] || instance_id="$(select_instance)"

  local backups
  backups="$(list_backups_for_instance "$instance_id" | sort)"
  [[ -z "$backups" ]] && { log "No backups"; return 0; }

  if [[ -n "${RETENTION_DAYS}" ]]; then
    local cutoff
    cutoff="$(date -d "-${RETENTION_DAYS} days" +%s)"
    while read -r b; do
      [[ -z "$b" ]] && continue
      local epoch
      epoch="$(date -d "${b/_/ }" +%s 2>/dev/null || echo 0)"
      if [[ "$epoch" -gt 0 && "$epoch" -lt "$cutoff" ]]; then
        log "Pruning ${b} (older than ${RETENTION_DAYS} days)"
        rclone purge "cos:${COS_BUCKET}/${COS_PREFIX}/${instance_id}/${b}" --config "$RCLONE_CONFIG"
      fi
    done <<< "$backups"
  fi

  if [[ -n "${RETENTION_COUNT}" ]]; then
    local total
    total="$(echo "$backups" | wc -l | tr -d ' ')"
    if [[ "$total" -gt "$RETENTION_COUNT" ]]; then
      local to_delete
      to_delete="$(echo "$backups" | head -n $((total - RETENTION_COUNT)))"
      while read -r b; do
        [[ -z "$b" ]] && continue
        log "Pruning ${b} (retention count)"
        rclone purge "cos:${COS_BUCKET}/${COS_PREFIX}/${instance_id}/${b}" --config "$RCLONE_CONFIG"
      done <<< "$to_delete"
    fi
  fi
}

show_config() {
  require_config
  cat "$CONFIG_FILE"
}

test_connection() {
  require_config
  load_config
  check_pg
  check_cos
  log "PG and COS connection OK"
}

configure() {
  ensure_dirs
  require_cmd gum
  while true; do
    PG_INSTANCE_ID="$(gum_input --placeholder "PG instance id (unique)")"
    [[ -n "$PG_INSTANCE_ID" ]] && break
  done

  local containers
  containers="$(docker ps --format '{{.Names}}' | tr '\n' ' ')"
  local default_container
  default_container="$(docker ps --format '{{.Names}}' | head -n 1)"

  if [[ -n "$containers" ]]; then
    PG_CONTAINER="$(echo "$containers" | xargs -n1 | gum choose --header "Select PostgreSQL container" --selected "$default_container")"
  else
    PG_CONTAINER="$(gum_input --placeholder "PostgreSQL container name or ID")"
  fi

  PG_USER="$(gum_input --placeholder "PostgreSQL superuser (default: postgres)")"
  [[ -z "$PG_USER" ]] && PG_USER="postgres"
  PG_PASSWORD="$(gum_input_password --placeholder "PostgreSQL password (optional)")"

  COS_BUCKET="$(gum_input --placeholder "COS bucket (e.g. mybucket-125xxxxxx)")"
  COS_ENDPOINT="$(gum_input --placeholder "COS S3 endpoint (e.g. cos.ap-shanghai.myqcloud.com)")"
  COS_SECRET_ID="$(gum_input --placeholder "SecretId")"
  COS_SECRET_KEY="$(gum_input_password --placeholder "SecretKey")"

  COS_PREFIX="pg-backup"

  SCHEDULE_CRON="$(gum_input --placeholder "Backup schedule (cron, default: 0 3 * * *)")"
  [[ -z "$SCHEDULE_CRON" ]] && SCHEDULE_CRON="0 3 * * *"
  RETENTION_DAYS="$(gum_input --placeholder "Retention days (default: 14, empty to disable)")"
  [[ -z "$RETENTION_DAYS" ]] && RETENTION_DAYS="14"
  RETENTION_COUNT="$(gum_input --placeholder "Retention count (optional)")"

  save_config
  log "Configuration saved to ${CONFIG_FILE}"
  log "If scheduler is running, restart it to apply changes: docker compose restart scheduler"
}

panel_menu() {
  while true; do
    local choice
    choice="$(gum choose --header "pgcos panel" \
      "backup-now" \
      "list" \
      "restore-latest" \
      "restore-select" \
      "modify-settings" \
      "prune" \
      "show-config" \
      "test-connection" \
      "update-self" \
      "test-restore" \
      "test-flow" \
      "help" \
      "exit")"

    case "$choice" in
      backup-now) backup_now ;;
      list)
        local instance_id
        instance_id="${PG_INSTANCE_ID}"
        [[ -n "$instance_id" ]] || instance_id="$(select_instance)"
        list_backups_for_instance "$instance_id"
        ;;
      restore-latest)
        local instance_id
        instance_id="${PG_INSTANCE_ID}"
        [[ -n "$instance_id" ]] || instance_id="$(select_instance)"
        restore_from "$instance_id" "$(latest_backup "$instance_id")"
        ;;
      restore-select)
        local instance_id
        instance_id="${PG_INSTANCE_ID}"
        [[ -n "$instance_id" ]] || instance_id="$(select_instance)"
        restore_from "$instance_id" "$(select_backup "$instance_id")"
        ;;
      modify-settings) configure ;;
      prune) prune_backups ;;
      show-config) show_config ;;
      test-connection) test_connection ;;
      update-self) update_self ;;
      test-restore) test_restore ;;
      test-flow) test_flow ;;
      help) echo "
configure    初始化/修改配置
backup-now   立即备份
list         列出备份（时间/年龄）
restore      恢复（latest/select）
prune        按保留策略清理旧备份
show-config  查看当前配置
test-connection  测试 PG/COS 连接
update-self  拉取最新镜像
    test-restore 一键测试恢复（新建临时 PG）
    test-flow    一键测试全流程（备份->恢复->验证->清理）
" ;;
      exit) break ;;
    esac
  done
}

scheduler() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    log "Config not found, scheduler will exit without restart"
    exit 0
  fi
  load_config
  ensure_dirs
  require_cmd supercronic

  local cron_file="$WORK_DIR/pgcos.cron"
  echo "${SCHEDULE_CRON:-0 3 * * *} /app/pgcos.sh backup-now" > "$cron_file"
  log "Scheduler started with cron: ${SCHEDULE_CRON:-0 3 * * *}"
  exec supercronic "$cron_file"
}

main() {
  local cmd="${1:-panel}"
  shift || true

  case "$cmd" in
    panel)
      if [[ ! -f "$CONFIG_FILE" ]]; then
        configure
      else
        load_config
      fi
      panel_menu
      ;;
    configure) configure ;;
    backup-now) backup_now ;;
    list)
      local instance_id
      instance_id="${PG_INSTANCE_ID}"
      [[ -n "$instance_id" ]] || instance_id="$(select_instance)"
      local backups
      backups="$(list_backups_for_instance "$instance_id" | sort)"
      list_backups_pretty "$instance_id" "$backups"
      local pick
      pick="$(prompt_backup_pick "$backups")"
      show_backup_details "$instance_id" "$pick"
      ;;
    restore)
      local instance_id
      local arg
      instance_id="${PG_INSTANCE_ID}"
      [[ -n "$instance_id" ]] || instance_id="$(select_instance)"
      arg="${1:-}"
      if [[ "$arg" == "latest" ]]; then
        restore_from "$instance_id" "$(latest_backup "$instance_id")"
      elif [[ -n "$arg" ]]; then
        restore_from "$instance_id" "$arg"
      else
        restore_from "$instance_id" "$(select_backup "$instance_id")"
      fi
      ;;
    prune) prune_backups ;;
    show-config) show_config ;;
    test-connection) test_connection ;;
    update-self) update_self ;;
    test-restore) test_restore ;;
    test-flow) test_flow ;;
    scheduler) scheduler ;;
    *)
      echo "Usage: $0 {panel|configure|backup-now|list|restore [latest|id]|prune|show-config|test-connection|update-self|test-restore|test-flow|scheduler}"
      exit 1
      ;;
  esac
}

main "$@"
