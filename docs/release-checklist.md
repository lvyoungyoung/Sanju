# 发布检查清单

## 后端发布

- 后端 Edge Function 和 SQL 发布前，先按 `docs/backend-release-process.md` 确认本地、GitHub、阿里云 Supabase 三者版本一致。
- Edge Function 默认从 GitHub Actions 的 `Backend Functions` 工作流发布，不再优先从阿里云网页编辑器手动复制。
- SQL migration 默认从 GitHub Actions 的 `Backend Database` 工作流发布。首次接入新环境时先跑 `baseline`，之后日常发布跑 `apply`。
- GitHub Actions Secrets 使用 `SUPABASE_API_URL`、`SUPABASE_API_KEY`、`SUPABASE_PROJECT_ID`、`SUPABASE_DB_PASSWORD` 和 `ALIYUN_ACCESS_TOKEN`；数据库 workflow 也兼容之前添加过的 `SUPABASE_PROJECT_REF`。不使用官方 Supabase 的 `SUPABASE_ACCESS_TOKEN`。
- 数据库 workflow 会设置 `SUPABASE_PLATFORM=aliyun`；本地手动跑阿里云 Supabase CLI 时也要设置这个变量，否则部分命令会误走官方 Supabase token 校验。
- 手动运行 `Backend Functions` 时，默认先选 `staging`，测试通过后再选 `production`。
- 手动运行 `Backend Database` 时，默认先选 `staging`，测试通过后再选 `production`。
- 发布前本地运行 `bash scripts/check-edge-functions.sh`，确认 `scripts/edge-functions.txt` 中的全部函数都能通过 `deno check`（当前 13 个）。
- 清理访客任务只能由运维服务调用：`cleanup-guest-generation-jobs` 要求 POST 和当前环境的 service-role Bearer 凭据；不能用普通用户令牌或客户端公开 key。每批最多 100 个任务，按 `hasMore` 继续，失败应重试而不是认定已清理。
- 本地跑 `deno test --no-lock --allow-read scripts/tests/stability-boundaries.test.ts scripts/tests/guest-credit-migration.test.ts`，验证维护接口权限、次数迁移边界和事务回滚。
- 客户端至少覆盖一个旧系统与当前系统的模拟器测试，不能只验证最新系统；购买回包跨账号、相同文本不同照片的测试不得跳过。
- 部署 staging 后运行 `node scripts/check-client-compatibility.mjs`，确认旧客户端兼容测试通过。
- 本地验证 iOS 构建时，默认按 `docs/ios-build-workflow.md` 执行，使用 `bash scripts/build-ios.sh simulator`。如果在 Codex 内验证，优先使用沙箱外构建。

- 新建 Supabase 环境后，必须开通实例访问公网；否则带 `npm:` import 的 Edge Function 部署可能返回 `504 upstream server is timing out`。
- 如果通过 GitHub Actions 部署 `delete-account`，确认工作流使用 `scripts/deploy-edge-functions.sh`，不要手动漏掉 `--no-verify-jwt`。

## 后端环境变量

- 正式环境确认 `GENERATION_VIOLATION_BAN_ENABLED=true`，开启“连续违规图片会临时禁用生成”的保护。代码默认开启；只有显式设为 `false` 才会关闭。
- 当前封禁策略：24 小时内 20 次高风险图片审核不通过，会临时禁用生成 24 小时。
- 图片审核最多等待 10 秒；超时会放行生成，明确返回高风险才拦截并计入违规次数。
- 测试期间如需临时关闭，可设 `GENERATION_VIOLATION_BAN_ENABLED=false`，这样单张违规图片仍会被拦截，但不会累计违规次数，也不会受已有封禁时间影响。
- 上线前确认 `IMAGE_MODERATION_DEBUG=false`，避免把图片审核失败详情返回给客户端。
