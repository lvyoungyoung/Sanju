# 后端发布流程

这份文档用于保证本地代码、GitHub 仓库、阿里云 AnalyticDB Supabase 线上环境三者一致。

## 核心原则

- 本地仓库是唯一源码来源。
- GitHub 记录每一次可追踪的后端变更。
- 阿里云 Supabase 线上环境只部署已经提交到 GitHub 的版本。
- 不从聊天记录、临时草稿或浏览器编辑器里的旧内容直接复制部署。

## Edge Function 发布

默认使用 GitHub Actions 发布，避免浏览器编辑器里残留旧代码导致线上和 GitHub 漂移。

如果同一次发布既包含 SQL migration 又包含 Edge Function，先执行 `Backend Database` 的 migration，再部署 Edge Function。这样函数不会先运行在缺少表结构或 RPC 的数据库上。

### GitHub Actions 发布

1. 在本地修改 `supabase/functions/<function-name>/index.ts`。
2. 如果新增或删除函数，同步更新 `scripts/edge-functions.txt` 和 `.github/workflows/backend-functions.yml` 的 `workflow_dispatch` 选项。
3. 本地运行检查。

   ```bash
   bash scripts/check-edge-functions.sh
   ```

4. 提交并推送到 GitHub。

   ```bash
   git status --short
   git add supabase/functions scripts .github/workflows docs
   git commit -m "<release message>"
   git push
   ```

5. 打开 GitHub 仓库的 `Actions` -> `Backend Functions` -> `Run workflow`。
6. 先选择 `target_environment`，默认部署到 `staging`。
7. 选择要部署的函数，或者选择 `all` 部署全部函数。
8. 部署到 staging 后，先运行旧客户端兼容测试。

   ```bash
   node scripts/check-client-compatibility.mjs
   ```

9. 兼容测试通过后，用 Debug 包真机走一遍关键路径。
10. 如果确认线上正常，再把同一个 commit 部署到 production。
11. 如果 production 确认正常，给当前 commit 打发布 tag。

   ```bash
   git tag backend-YYYYMMDD-N
   git push origin backend-YYYYMMDD-N
   ```

GitHub Actions 需要在仓库的 `Settings` -> `Environments` 中创建两个环境：

- `staging`
- `production`

每个 environment 里分别配置自己的 Secrets：

- `SUPABASE_API_URL`，当前项目为 `https://spb-bp103246ivn7q0nl.supabase.opentrust.net`
- `SUPABASE_API_KEY`，填写阿里云 Supabase 的 `service_role` key

当前 API URL：

- staging: `https://spb-bp1364k407p37qn7.supabase.opentrust.net`
- production: `https://spb-bp103246ivn7q0nl.supabase.opentrust.net`

部署脚本会校验 `target_environment` 和 `SUPABASE_API_URL` 是否匹配，避免把 staging 部署误打到 production。

`scripts/deploy-edge-functions.sh` 会固定按 `scripts/edge-functions.txt` 中的清单部署，避免误部署临时目录。脚本使用阿里云 AnalyticDB Supabase 的 `functions-cli` 发布；`delete-account` 会自动带上 `--no-verify-jwt`，保持当前线上配置。

### 新环境初始化要求

新建 staging / production 项目后，先确认阿里云 Supabase 已开通“实例访问公网”或等价的出公网能力。

原因：当前 Edge Functions 使用了 `npm:` import，例如 `npm:@supabase/supabase-js@2`。阿里云在部署/构建函数时需要访问公网拉取依赖。如果实例没有出公网能力，网页里部署无依赖的 `ping` 函数可能成功，但通过 GitHub Actions / `functions-cli` 部署带 import 的函数会稳定失败，并返回类似：

```text
Response status code: 504
The upstream server is timing out
```

排查顺序：

1. 先确认 GitHub Actions 日志里的 `target_environment` 和 `SUPABASE_API_URL` 正确。
2. 确认 `SUPABASE_API_KEY` 是目标环境自己的 `service_role` key。
3. 如果无依赖的 `ping` 函数能部署，但带 `npm:` import 的函数 504，优先检查实例是否已绑定/开通访问公网能力。
4. 开通后重新部署 `cleanup-guest-generation-jobs` 做验证。

### 兜底手动发布

1. 在本地修改 `supabase/functions/<function-name>/index.ts`。
2. 运行语法检查。

   ```bash
   deno check supabase/functions/<function-name>/index.ts
   ```

3. 提交并推送到 GitHub。

   ```bash
   git status --short
   git add supabase/functions/<function-name>/index.ts
   git commit -m "<release message>"
   git push
   ```

4. 记录当前 commit。

   ```bash
   git rev-parse --short HEAD
   ```

5. 只有当 GitHub Actions / CLI 发布不可用时，才从本地仓库当前版本复制完整函数内容到阿里云 Supabase Edge Function 编辑器。

   ```bash
   pbcopy < supabase/functions/<function-name>/index.ts
   ```

6. 在阿里云后台部署函数。
7. 部署后用真机走一遍关键路径。
8. 如果确认线上正常，给当前 commit 打发布 tag。

   ```bash
   git tag backend-YYYYMMDD-N
   git push origin backend-YYYYMMDD-N
   ```

## SQL Migration 手动发布

默认使用 GitHub Actions 发布 SQL migration，避免 staging 和 production 漏执行某个 RPC 或表结构变更。详细说明见 `docs/database-migrations.md`。

### GitHub Actions 发布

1. 所有数据库结构或 RPC 变更都新增 migration 文件，不修改已经在线上执行过的旧 migration。
2. 文件名使用递增日期和清晰描述，例如：

   ```text
   supabase/migrations/20260502_example_change.sql
   ```

3. 本地提交并推送 SQL 文件。
4. 打开 GitHub 仓库的 `Actions` -> `Backend Database` -> `Run workflow`。
5. 先选择 `staging` + `apply`。
6. staging 通过兼容测试和真机测试后，再选择 `production` + `apply`。
7. 如果 SQL 涉及函数重建，先在测试数据上验证返回结构，再更新客户端。

首次接入新环境时，先用 `baseline` 登记已经手动执行过的历史 migration，再用 `status` 确认没有 pending migration。

### 兜底手动发布

只有当 GitHub Actions / 数据库连接串不可用时，才回退到手动执行：

1. 确认 migration 文件已经提交并推送到 GitHub。
2. 在阿里云 Supabase SQL Editor 执行同一个 migration 文件的完整内容。
3. 执行成功后记录 commit 和执行时间。

## 发布记录模板

每次后端发布后，在 issue、备忘录或发布记录里写一条：

```text
日期：
Git commit：
Git tag：
部署内容：
部署函数：
执行 SQL：
验证结果：
回滚方案：
```

## 回滚原则

- Edge Function 回滚：找到上一个稳定 tag，从该 tag 复制对应函数内容重新部署。
- SQL 回滚：不要直接删除线上数据或强行回滚 migration，先写修复 SQL。
- 客户端兼容：后端返回字段尽量只增不删，避免旧版本 App 崩溃。

## 当前部署函数

- `generate-memory-v2`
- `moderate-image-v1`
- `recover-guest-generation`
- `confirm-purchase`
- `delete-account`
- `migrate-guest-credits`
- `cleanup-guest-generation-jobs`
