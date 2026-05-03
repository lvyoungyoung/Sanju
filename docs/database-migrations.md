# 数据库 Migration 发布

这套流程用于把 SQL / RPC / RLS / 表结构变更纳入 GitHub 发布链路。

## 核心原则

- 数据库结构变更必须写进 `supabase/migrations/*.sql`。
- 已经执行过的 migration 不要修改；如果要修复，新增一个更晚的 migration。
- staging 和 production 执行同一份 Git commit 里的 migration。
- 不从 staging 直接复制数据库状态到 production。

## GitHub Secrets

在 GitHub 仓库的 `Settings` -> `Environments` 中，给 `staging` 和 `production` 分别添加：

- `SUPABASE_PROJECT_ID`，项目 ID，例如 `spb-bp1364k407p37qn7`。如果已经配置过 `SUPABASE_PROJECT_REF`，workflow 也会兼容读取
- `SUPABASE_DB_PASSWORD`，数据库账号 `postgres` 的密码
- `ALIYUN_ACCESS_TOKEN`，格式为 `<AccessKeyID>|<AccessKeySecret>`

如果地域不是杭州，可以在对应 environment 的 Variables 里覆盖：

- `ALIYUN_REGION_ID`，当前默认 `cn-hangzhou`

建议给 GitHub 的 `production` environment 配置 required reviewer。这样 production migration 需要人工确认后才会执行，不会因为误点或误配置直接影响线上。

## 首次接入：baseline

因为历史 migration 已经手动执行过，第一次接入时不要重新执行旧 SQL。

对 staging 和 production 各跑一次：

1. 打开 GitHub `Actions` -> `Backend Database` -> `Run workflow`。
2. `target_environment` 选择目标环境。
3. `mode` 选择 `baseline`。
4. 运行成功后，再用 `mode=status` 确认 `Pending: 0`。

`baseline` 只会把当前仓库里的 migration 文件登记到 Supabase CLI 自带的 migration history 表，不会执行 SQL 内容。

注意：Supabase CLI 使用 migration 文件名前缀作为版本号，所以文件名必须是唯一时间戳，例如：

```text
20260503143000_example_change.sql
```

## 日常发布

推荐顺序：

1. 新增 migration 文件，例如 `supabase/migrations/20260503143000_example.sql`。
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

这套流程使用阿里云版 Supabase CLI，不是官方 Supabase CLI。官方 CLI 不支持阿里云文档里的 `--project-ref` 参数。

如果本地已经安装阿里云版 CLI，可以运行：

```bash
TARGET_ENVIRONMENT=staging \
SUPABASE_PROJECT_ID=spb-bp1364k407p37qn7 \
EXPECTED_SUPABASE_PROJECT_ID=spb-bp1364k407p37qn7 \
SUPABASE_DB_PASSWORD="<postgres-password>" \
ALIYUN_ACCESS_TOKEN="<AccessKeyID>|<AccessKeySecret>" \
ALIYUN_REGION_ID=cn-hangzhou \
bash scripts/supabase-db-migrations.sh status
```

如果要本地登记历史 migration：

```bash
bash scripts/supabase-db-migrations.sh baseline
```

正常情况下，production 只通过 GitHub Actions 执行。

## 使用的 migration 表

这里使用 Supabase CLI 自带的 migration history 表，而不是我们自建表。
`baseline` 底层调用 `supabase migration repair --project-ref ... --password ... --status applied`，`apply` 底层调用 `supabase db push --project-ref ... --password ...`。
