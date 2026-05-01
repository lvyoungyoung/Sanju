# 阿里云 Supabase 迁移清单

这份清单基于阿里云官方 `supabase-cli migrate-project` 方案，适用于：

- 源端：Supabase Cloud
- 目标端：阿里云 AnalyticDB Supabase

## 1. 前置条件

- 本机已安装并启动 Docker
- 本机已下载阿里云提供的 `supabase-cli`
- 源端和目标端的 API / 数据库网络都可访问

## 2. 源端需要准备的信息

- `SOURCE_PROJECT_REF`
- `SOURCE_ANON_KEY`
- `SOURCE_SERVICE_ROLE_KEY`
- `SOURCE_DATABASE_URL`

备注：
- 如果源端数据库直连不通，优先改用 Transaction pooler 地址。

## 3. 目标端需要准备的信息

- `TARGET_API_URL`
- `TARGET_ANON_KEY`
- `TARGET_SERVICE_ROLE_KEY`
- `TARGET_DATABASE_URL`

## 4. 当前项目迁移后重点验收项

- Apple 登录
- 匿名登录
- 生成
- 生成恢复
- 购买到账
- 删除账号
- 回忆同步
- 小组件图片和句子显示

## 5. 当前项目后端资产

### Edge Functions

- `cleanup-guest-generation-jobs`
- `confirm-purchase`
- `delete-account`
- `generate-memory-v2`
- `migrate-guest-credits`
- `recover-guest-generation`
- `store-apple-auth-credential`

### 关键 Secrets

- `MIMO_API_KEY`
- `MIMO_BASE_URL`
- `KIMI_API_KEY`
- `KIMI_BASE_URL`
- `APPLE_TEAM_ID`
- `APPLE_CLIENT_ID`
- `APPLE_KEY_ID`
- `APPLE_PRIVATE_KEY`

### Storage

- bucket: `memories`

## 6. 建议执行顺序

1. 安装并启动 Docker
2. 下载阿里云 `supabase-cli`
3. 填好 `migration.env`
4. 先跑一次 `--dry-run`
5. dry-run 通过后跑正式迁移
6. 迁移完成后逐项做验收
7. 最后再把 iOS 配置切到阿里云项目

## 7. 命令模板

```bash
source ./migration.env

./supabase-cli login

./supabase-cli migrate-project \
  --source-project-ref "$SOURCE_PROJECT_REF" \
  --source-anon-key "$SOURCE_ANON_KEY" \
  --source-service-role-key "$SOURCE_SERVICE_ROLE_KEY" \
  --target-api-url "$TARGET_API_URL" \
  --target-anon-key "$TARGET_ANON_KEY" \
  --target-service-role-key "$TARGET_SERVICE_ROLE_KEY" \
  --target-database-url "$TARGET_DATABASE_URL" \
  --dry-run
```

```bash
source ./migration.env

./supabase-cli migrate-project \
  --source-project-ref "$SOURCE_PROJECT_REF" \
  --source-anon-key "$SOURCE_ANON_KEY" \
  --source-service-role-key "$SOURCE_SERVICE_ROLE_KEY" \
  --target-api-url "$TARGET_API_URL" \
  --target-anon-key "$TARGET_ANON_KEY" \
  --target-service-role-key "$TARGET_SERVICE_ROLE_KEY" \
  --target-database-url "$TARGET_DATABASE_URL"
```
