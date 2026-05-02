# 发布检查清单

## 后端发布

- 后端 Edge Function 和 SQL 发布前，先按 `docs/backend-release-process.md` 确认本地、GitHub、阿里云 Supabase 三者版本一致。
- Edge Function 默认从 GitHub Actions 的 `Backend Functions` 工作流发布，不再优先从阿里云网页编辑器手动复制。
- GitHub Actions Secrets 使用 `SUPABASE_API_URL` 和 `SUPABASE_API_KEY`；不使用官方 Supabase 的 `SUPABASE_ACCESS_TOKEN` / `SUPABASE_PROJECT_REF`。
- 发布前本地运行 `bash scripts/check-edge-functions.sh`，确认 7 个函数都能通过 `deno check`。
- 如果通过 GitHub Actions 部署 `delete-account`，确认工作流使用 `scripts/deploy-edge-functions.sh`，不要手动漏掉 `--no-verify-jwt`。

## 后端环境变量

- 正式环境确认 `GENERATION_VIOLATION_BAN_ENABLED=true`，开启“连续违规图片会临时禁用生成”的保护。代码默认开启；只有显式设为 `false` 才会关闭。
- 当前封禁策略：24 小时内 20 次高风险图片审核不通过，会临时禁用生成 24 小时。
- 图片审核最多等待 10 秒；超时会放行生成，明确返回高风险才拦截并计入违规次数。
- 测试期间如需临时关闭，可设 `GENERATION_VIOLATION_BAN_ENABLED=false`，这样单张违规图片仍会被拦截，但不会累计违规次数，也不会受已有封禁时间影响。
- 上线前确认 `IMAGE_MODERATION_DEBUG=false`，避免把图片审核失败详情返回给客户端。
