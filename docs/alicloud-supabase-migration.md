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
- `IMAGE_MODERATION_ENABLED`
- `IMAGE_MODERATION_DEBUG`
- `IMAGE_MODERATION_FUNCTION_URL`
- `GENERATION_VIOLATION_BAN_ENABLED`
- `ALIBABA_CLOUD_ACCESS_KEY_ID`
- `ALIBABA_CLOUD_ACCESS_KEY_SECRET`
- `ALIYUN_IMAGE_MODERATION_ENDPOINT`
- `ALIYUN_IMAGE_MODERATION_SERVICE`
- `APPLE_TEAM_ID`
- `APPLE_CLIENT_ID`
- `APPLE_KEY_ID`
- `APPLE_PRIVATE_KEY`

图片审核建议配置：

- `IMAGE_MODERATION_ENABLED=true`
- `IMAGE_MODERATION_DEBUG=false`
- `IMAGE_MODERATION_FUNCTION_URL=`（可留空，默认使用 `SUPABASE_URL/functions/v1/moderate-image-v1`）
- `GENERATION_VIOLATION_BAN_ENABLED=true`（正式环境开启连续违规封禁；测试时如需临时关闭可改为 `false`）
- `ALIYUN_IMAGE_MODERATION_ENDPOINT=https://green-cip.cn-shanghai.aliyuncs.com`
- `ALIYUN_IMAGE_MODERATION_SERVICE=baselineCheck`

`ALIBABA_CLOUD_ACCESS_KEY_ID` 和 `ALIBABA_CLOUD_ACCESS_KEY_SECRET` 建议使用只授权内容安全图片审核的 RAM 用户，不要使用主账号 AccessKey。
如果线上临时排查 `image_moderation_unavailable`，可以短暂把 `IMAGE_MODERATION_DEBUG` 设为 `true`，客户端响应会带上阿里云调用失败详情；排查完成后请改回 `false`。
图片审核现在拆成独立 Edge Function：请先部署 `moderate-image-v1`，再部署 `generate-memory-v2`。
`generate-memory-v2` 最多等待图片审核 10 秒；如果审核函数超时未返回，会记录后端日志并放行生成，已明确返回高风险的图片仍会被拦截。
连续违规封禁策略目前是：24 小时内 20 次高风险图片审核不通过，会临时禁用生成 24 小时。

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
