# 发布检查清单

## 后端发布

- 后端 Edge Function 和 SQL 发布前，先按 `docs/backend-release-process.md` 确认本地、GitHub、阿里云 Supabase 三者版本一致。
- Edge Function 默认从 GitHub Actions 的 `Backend Functions` 工作流发布，不再优先从阿里云网页编辑器手动复制。
- SQL migration 默认从 GitHub Actions 的 `Backend Database` 工作流发布。首次接入新环境时先跑 `baseline`，之后日常发布跑 `apply`。
- GitHub Actions Secrets 使用 `SUPABASE_API_URL`、`SUPABASE_API_KEY`、`SUPABASE_PROJECT_ID`、`SUPABASE_DB_HOST` 和 `SUPABASE_DB_PASSWORD`；数据库 workflow 也兼容之前添加过的 `SUPABASE_PROJECT_REF`。不使用官方 Supabase 的 `SUPABASE_ACCESS_TOKEN`。
- 手动运行 `Backend Functions` 时，默认先选 `staging`，测试通过后再选 `production`。
- 手动运行 `Backend Database` 时，默认先选 `staging`，测试通过后再选 `production`。
- 发布前本地运行 `bash scripts/check-edge-functions.sh`，确认 7 个函数都能通过 `deno check`。
- 部署 staging 后运行 `node scripts/check-client-compatibility.mjs`，确认旧客户端兼容测试通过。
- 新建 Supabase 环境后，必须开通实例访问公网；否则带 `npm:` import 的 Edge Function 部署可能返回 `504 upstream server is timing out`。
- 如果通过 GitHub Actions 部署 `delete-account`，确认工作流使用 `scripts/deploy-edge-functions.sh`，不要手动漏掉 `--no-verify-jwt`。

## 后端环境变量

- 正式环境确认 `GENERATION_VIOLATION_BAN_ENABLED=true`，开启“连续违规图片会临时禁用生成”的保护。代码默认开启；只有显式设为 `false` 才会关闭。
- 当前封禁策略：24 小时内 20 次高风险图片审核不通过，会临时禁用生成 24 小时。
- 图片审核最多等待 10 秒；超时会放行生成，明确返回高风险才拦截并计入违规次数。
- 测试期间如需临时关闭，可设 `GENERATION_VIOLATION_BAN_ENABLED=false`，这样单张违规图片仍会被拦截，但不会累计违规次数，也不会受已有封禁时间影响。
- 上线前确认 `IMAGE_MODERATION_DEBUG=false`，避免把图片审核失败详情返回给客户端。
