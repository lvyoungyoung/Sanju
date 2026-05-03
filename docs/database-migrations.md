# 数据库 Migration 发布

这套流程用于把 SQL / RPC / RLS / 表结构变更纳入 GitHub 发布链路。

## 核心原则

- 数据库结构变更必须写进 `supabase/migrations/*.sql`。
- 已经执行过的 migration 不要修改；如果要修复，新增一个更晚的 migration。
- staging 和 production 执行同一份 Git commit 里的 migration。
- 不从 staging 直接复制数据库状态到 production。

## GitHub Secrets

在 GitHub 仓库的 `Settings` -> `Environments` 中，给 `staging` 和 `production` 分别添加：

- `SUPABASE_DATABASE_URL`

这个值填写目标环境的 PostgreSQL 连接串，建议包含 `sslmode=require`。例如：

```text
postgresql://<user>:<password>@<project-host>:5432/<database>?sslmode=require
```

当前 workflow 会校验连接串里是否包含目标项目 ID，避免把 staging migration 打到 production。

建议给 GitHub 的 `production` environment 配置 required reviewer。这样 production migration 需要人工确认后才会执行，不会因为误点或误配置直接影响线上。

## 首次接入：baseline

因为历史 migration 已经手动执行过，第一次接入时不要重新执行旧 SQL。

对 staging 和 production 各跑一次：

1. 打开 GitHub `Actions` -> `Backend Database` -> `Run workflow`。
2. `target_environment` 选择目标环境。
3. `mode` 选择 `baseline`。
4. 运行成功后，再用 `mode=status` 确认 `Pending: 0`。

`baseline` 只会把当前仓库里的 migration 文件登记到 `public.sanju_schema_migrations`，不会执行 SQL 内容。

## 日常发布

推荐顺序：

1. 新增 migration 文件，例如 `supabase/migrations/20260503_example.sql`。
2. 提交并推送到 GitHub。
3. `Backend Database` 选择 `staging` + `apply`。
4. `Backend Functions` 选择 `staging` + 需要部署的函数。
5. 运行旧客户端兼容测试。

   ```bash
   node scripts/check-client-compatibility.mjs
   ```

6. Debug 真机走一遍关键路径。
7. 确认没问题后，`Backend Database` 选择 `production` + `apply`。
8. 再 `Backend Functions` 选择 `production` + 同一批函数。

## 本地查看状态

如果本地有数据库连接串，可以运行：

```bash
SUPABASE_DATABASE_URL="<database-url>" \
TARGET_ENVIRONMENT=staging \
EXPECTED_SUPABASE_PROJECT_ID=spb-bp1364k407p37qn7 \
npm run db:migrate:status
```

对 production 本地执行 `baseline` 或 `apply` 时，需要额外加：

```bash
DATABASE_MIGRATION_ALLOW_PRODUCTION=1
```

正常情况下，production 只通过 GitHub Actions 执行。

## 为什么要有 migration 表

脚本会维护 `public.sanju_schema_migrations`：

- `version`：migration 文件名。
- `checksum`：文件内容 hash。
- `mode`：是 `baseline` 登记，还是 `apply` 执行。

如果已经登记过的 migration 文件内容被改了，脚本会直接失败。这是为了避免“线上执行过的 SQL 和仓库里的 SQL 不一致”。
