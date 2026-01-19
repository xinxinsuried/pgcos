# pgcos — PostgreSQL 全量备份到腾讯云 COS

> 仅逻辑全量备份（实例级），无需改 PostgreSQL 配置。

## 特性
- 仅使用 `docker exec` 调用 PG 容器内 `pg_dump/pg_dumpall/psql/pg_restore`
- 每次备份：`globals` + 每个数据库独立 `pg_dump -Fc`
- zstd 压缩 + sha256 校验
- COS 上传：rclone（S3 兼容 TencentCOS）
- 一键交互式面板（TUI）+ 定时备份
- 支持跨服务器恢复

## 重要限制
- **不会修改 PostgreSQL 配置**（不使用 WAL/归档/增量）。
- **目标 PG 版本必须 >= 源版本**，否则可能恢复失败。
- 如数据库依赖特定扩展（extension），目标容器必须支持该扩展。

## 最少步骤快速开始
1. 克隆并启动：
```
git clone <your_repo>
cd pgcos
docker compose up -d
```
2. 进入交互面板完成初始化：
```
docker compose run --rm panel
```
3. 之后由 scheduler 自动按配置定时备份。
4. 首次会要求填写 `instance_id`（用于多实例区分，必须手动填写）。

> 配置保存在 `./config/config.env`，COS 密钥仅在宿主机 `./config/` 中保存。
> 修改配置后请执行：`docker compose restart scheduler`

## 交互面板功能
- configure（初始化/修改配置）
- backup-now
- list
- restore（latest / select）
- prune
- show-config
- test-connection
- update-self（重新拉取镜像）

## 备份目录结构
```
s3://{bucket}/pg-backup/{instance_id}/{YYYY-MM-DD_HH-MM-SS}/globals.sql.zst
s3://{bucket}/pg-backup/{instance_id}/{YYYY-MM-DD_HH-MM-SS}/{dbname}.dump.zst
s3://{bucket}/pg-backup/{instance_id}/{YYYY-MM-DD_HH-MM-SS}/*.sha256
s3://{bucket}/pg-backup/{instance_id}/{YYYY-MM-DD_HH-MM-SS}/metadata.json
```

## 恢复流程（自动）
1. 恢复 globals
2. 创建数据库（若不存在）
3. `pg_restore --clean --if-exists`

## 多实例支持
- 初始化时会要求填写 `instance_id`（必须手动输入），备份将写入对应实例目录。
- 恢复/列表/清理时会读取实例列表供选择。

## 命令说明（中文）
- backup-now：立即备份
- list：列出备份（时间/年龄/大小）
- restore：恢复（latest/select）
- prune：按保留策略清理旧备份
- update-self：重新拉取当前镜像

## 常见错误
- **pg_dump/psql 不存在**：该工具只通过 `docker exec` 调用 PG 容器里的工具，请确保容器内已有 `pg_dump/psql`。
- **权限不足**：建议使用 PG 超级用户（默认 `postgres`）。
- **COS 无权限**：请使用 COS 子账号最小权限，仅允许目标 prefix 读写。

## GHCR 镜像
- 拉取：
```
docker pull ghcr.io/<GITHUB_USERNAME>/pgcos:latest
```
- 本地登录 GHCR 请使用 PAT（不要在 Actions 或配置中存明文密码）。

## 发布到 GHCR（最少步骤）
1. 将本项目推送到你的 GitHub 仓库（仓库名可自定义）。
2. 在仓库中打一个 tag（例如 `v1.0.0`）。
3. GitHub Actions 会自动构建并推送镜像到：
	`ghcr.io/<GITHUB_USERNAME>/pgcos:latest` 和 `ghcr.io/<GITHUB_USERNAME>/pgcos:v1.0.0`

## 备份/恢复演练
- 同机备份：
```
docker compose run --rm panel
# 选择 configure -> test-connection -> backup-now
```
- 异机恢复：
```
# 新机器启动空 PG 容器（版本不低于源）
docker compose up -d

docker compose run --rm panel
# 选择 configure（指向新 PG 容器 + 同一 COS） -> restore latest/select
```

## 安全建议
- COS SecretId/SecretKey 仅保存在 `./config/`，不会写入镜像层。
- 建议使用 COS 子账号，并限制到目标 prefix 的读写权限。

## License
MIT
