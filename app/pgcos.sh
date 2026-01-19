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
  pg_exec psql -U "$PG_USER" -t -A -c "select datname from pg_database where datistemplate=false" postgres
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
  while read -r db; do
    [[ -z "$db" ]] && continue
    log "Dumping $db"
    pg_exec pg_dump -U "$PG_USER" -Fc "$db" > "$dir/$db.dump"
    zstd -T0 -19 "$dir/$db.dump" -o "$dir/$db.dump.zst"
    rm -f "$dir/$db.dump"
    sha256sum "$dir/$db.dump.zst" > "$dir/$db.dump.zst.sha256"
  done < <(list_pg_databases)

  log "Uploading to COS"
  rclone copy "$dir" "cos:${COS_BUCKET}/${COS_PREFIX}/${PG_INSTANCE_ID}/${ts}" --config "$RCLONE_CONFIG"
  rm -rf "$dir"
  log "Backup complete: ${ts}"
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
    zstd -d "$dump" -o "$dir/$db.dump"
    pg_exec pg_restore -U "$PG_USER" --clean --if-exists -d "$db" "$dir/$db.dump"
    rm -f "$dir/$db.dump"
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
      help) echo "Commands: configure | backup-now | list | restore latest|select | prune | show-config | test-connection" ;;
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
      list_backups_for_instance "$instance_id"
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
    scheduler) scheduler ;;
    *)
      echo "Usage: $0 {panel|configure|backup-now|list|restore [latest|id]|prune|show-config|test-connection|scheduler}"
      exit 1
      ;;
  esac
}

main "$@"
