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

1. 在本地修改 `supabase/functions/<function-name>/` 下的入口和业务模块；依赖文件随函数打包，不是独立的部署目标。
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
- `SUPABASE_PROJECT_ID`，填写当前 environment 对应的项目 ID；如果已经配置过 `SUPABASE_PROJECT_REF`，数据库 workflow 也会兼容读取
- `SUPABASE_DB_PASSWORD`，数据库账号 `postgres` 的密码
- `ALIYUN_ACCESS_TOKEN`，数据库 migration workflow 使用，格式为 `<AccessKeyID>|<AccessKeySecret>`

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

5. 只有当 GitHub Actions / CLI 发布不可用时，才考虑阿里云 Supabase Edge Function 编辑器。必须保留全部相对导入依赖及目录结构；不能只粘贴 `index.ts`。编辑器不支持多文件依赖时，恢复 CLI 发布，不手动拼接或遗漏模块。

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

## 图片生成模型

自 2026-10-08 起，`generate-memory-v2` 在 staging 和 production 的生成顺序为
DeepSeek (`deepseek-flash`，关闭思考) -> MiMo (`mimo-v2.6-flash`) -> Kimi。
每个模型的请求上限为 20 秒，包含读取响应体；保持原有 90 秒总请求预算。
仅图片生成切换模型；朗读、主题意图解释及缺失元数据的后台修复仍沿用原有模型。

发布前，先在 **目标环境的 Edge Functions 运行环境变量** 中添加（两套环境独立配置）：

```text
DEEPSEEK_API_KEY=<DeepSeek API key>
DEEPSEEK_BASE_URL=https://api.deepseek.com/chat/completions
```

这里的 URL 必须是完整接口地址；代码没有默认地址。密钥不要提交到 GitHub，
也不要仅配置在本地测试文件或 GitHub Actions Secrets 中：函数需要运行环境中的值。
已有 `MIMO_API_KEY` / `MIMO_BASE_URL` / `KIMI_API_KEY` / `KIMI_BASE_URL` 继续保留用于兜底。
缺少 DeepSeek 配置时，目标环境会在启动生成前明确返回配置错误，不创建任务、不扣次数。

环境只根据服务端 `SUPABASE_URL` 的可信项目域名判断：
- staging：`spb-bp1364k407p37qn7.supabase.opentrust.net` 或 `api-staging.sanju.cc`。
- production：`spb-bp103246ivn7q0nl.supabase.opentrust.net` 或 `api.sanju.cc`。

其他未知项目仍走 MiMo -> Kimi。
不能用请求 URL、客户端 Header 或 `SUPABASE_LOCAL_URL` 改变模型选择。

先在 Backend Database 对目标环境应用
`20261008000000_allow_deepseek_generation_provider.sql`，让数据库接受 `provider=deepseek`。
原始托管 schema 的 `memories_provider_check` 只允许 MiMo/Kimi；漏跑此迁移会导致
模型成功、图片上传成功，但最终保存报 `23514`。迁移不改保存/扣次数事务，
也会扩展已经存在的同名匿名任务/生成任务 provider 约束，保留空值及原有提供方。
完成配置和迁移后，在 Backend Functions 中选择目标环境和 `generate-memory-v2` 发布。
先验证 staging，再把同一 commit 发布到 production。此次 production 模型切换
没有新增 migration，但 production 必须已应用上面的已有迁移。
若目标环境已经应用此迁移，无需重复执行；仍需部署最新 `generate-memory-v2` 来切换默认模型。
**无需更新客户端或修改 Nginx；不必更新其他 Edge Function。**
客户端收到的句子、分类和表达用途格式不变，原有事务保存/扣次数、恢复、后台向量化不变。
成功结果的 `provider` 为实际生成方；`mimo_failure_reason` 仍只记录 MiMo 的失败，
DeepSeek 的失败原因写入 Edge Function 日志。staging Xcode 耗时日志会出现
`server.deepseek`，兜底时还会显示 `server.mimo` / `server.kimi`。
显示 `server.deepseek` 需客户端包含该阶段的日志白名单修复；旧客户端仍可正常生成。

部署后分别验证匿名与登录用户生成、播放及学习主题匹配。
本地离线测试覆盖两种账号、环境隔离、鉴权请求格式、超时/无效 JSON/HTTP 错误兜底、
审核拒绝、全部模型失败不扣次数、重复请求及提交后断线恢复；这些不等于线上部署验证。

### Production 切换核对

1. 确认 production 的待执行 migration 清单；如有其他未验证迁移，不要一并盲目发布。
2. 应用 `20261008000000_allow_deepseek_generation_provider.sql`（若尚未应用）。
3. 配置 production 的 `DEEPSEEK_API_KEY` / `DEEPSEEK_BASE_URL`，保留 MiMo/Kimi 兜底配置。
4. 部署 production 的最新 `generate-memory-v2`。
5. 验证登录与匿名用户生成、扣一次、回忆保存和恢复；旧客户端仍返回三句，新客户端返回两组三句。

回滚模型顺序可将 `generate-memory-v2` 重新部署为 `584a901` 的版本，production 会恢复
MiMo -> Kimi；不必回滚放宽 provider 的迁移，也不应删除已有 DeepSeek 生成记录。

## SQL Migration 手动发布

默认使用 GitHub Actions 发布 SQL migration，避免 staging 和 production 漏执行某个 RPC 或表结构变更。详细说明见 `docs/database-migrations.md`。

### GitHub Actions 发布

1. 所有数据库结构或 RPC 变更都新增 migration 文件，不修改已经在线上执行过的旧 migration。
2. 文件名使用递增日期和清晰描述，例如：

   ```text
   supabase/migrations/20260502143000_example_change.sql
   ```

3. 本地提交并推送 SQL 文件。
4. 打开 GitHub 仓库的 `Actions` -> `Backend Database` -> `Run workflow`。
5. 先选择 `staging` + `apply`。
6. staging 通过兼容测试和真机测试后，再选择 `production` + `apply`。
7. 如果 SQL 涉及函数重建，先在测试数据上验证返回结构，再更新客户端。

首次接入新环境时，先用 `baseline` 登记已经手动执行过的历史 migration，再用 `status` 确认没有 pending migration。

### 兜底手动发布

只有当 GitHub Actions / 阿里云 Supabase CLI 不可用时，才回退到手动执行：

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

以 `scripts/edge-functions.txt` 为准，新增函数时同步更新 Actions 选项。

- `generate-memory-v2`
- `moderate-image-v1`
- `recover-guest-generation`
- `confirm-purchase`
- `create-study-scene`
- `delete-account`
- `migrate-guest-credits`
- `cleanup-guest-generation-jobs`
- `extract-study-topic-expressions`
- `process-generation-enrichment`
- `review-study-scene`
- `synthesize-speech`
- `update-profile-avatar`

### 维护接口鉴权

`cleanup-guest-generation-jobs` 仅接受 POST，`Authorization` 必须是
`Bearer <当前环境 SUPABASE_SERVICE_ROLE_KEY>`。凭据只留在服务端或运维任务中，
不要放进 App、公开配置、URL 或日志。原有调度若使用普通 JWT，需要改用此服务端凭据。
无需新增环境变量或 Nginx 配置。每批最多处理 100 条过期记录，`hasMore=true` 时可再次调用。
Storage 删除失败会保留任务；数据库删除失败会返回 500，重试可继续清理。

### 购买函数基线缺口

仓库暂未保存线上 `confirm_purchase_atomically(uuid,text,text,integer)` 的创建定义。
不要凭猜测重建或覆盖生产函数。新环境初始化前，应在获得授权后从已验证环境导出
函数定义及其依赖，去除敏感信息、复核权限，再补入版本管理并测试事务原子性。
本次稳定性修复没有更改该购买事务或购买 Edge Function。

### 匿名次数迁移流水

`20261008001000_allow_guest_credit_merge_transactions.sql` 将 `merge_local` 加入
`generation_transactions_reason_check`，保留原有四种流水类型和非负余额约束。
旧约束会拒绝有剩余次数的匿名迁移；失败事务会回滚余额及迁移标记，不需要手动修正次数。
先通过 `Backend Database` 在 staging 执行 `apply`，验证有剩余次数的匿名用户登录已有账号，
再按发布流程应用到 production。执行后重新登录即可重试，重复迁移不会重复加次数。
本次只需这个新增数据库迁移，无需更新 Edge Function、客户端、环境变量或 Nginx。

### 移除句子风格设置

2026-10-08 客户端生成偏好只保留难度，生成请求不再包含 `languageStyle`。
部署 `generate-memory-v2` 后，所有模型统一使用自然日常口语；旧请求中的风格字段被忽略。
保留 `profiles.language_style` 列和原有生成响应、恢复及扣次数事务，不需要新增 migration，
也不需要部署 `recover-guest-generation` 或 `migrate-guest-credits`，无需环境变量或代理调整。

### 恢复 Gemini 模板之前的提示词

2026-10-08 按用户要求完整恢复至 `5f40800` 中的生成提示词，不再使用 Gemini 的
四种自适应风格。启蒙 3–6 词、初级 6–10 词、中级 10–16 词；场景表达恢复为
感受、可能对别人说的话、发生了什么的顺序。客户端不恢复语言风格设置，
也不撤回之后新增的生成完成页单轮“翻一翻”。
原 JSON 输出要求、分类、表达用途、保存扣次事务、恢复和模型回退不变。
只需部署 `generate-memory-v2`，无需新增 migration、更新客户端、其他函数、环境变量或代理。

### 生成恢复与本地同步一致性修复

2026-10-10 匿名生成成功响应、重复生成请求和恢复响应统一使用 `guest_generation_jobs.id`
作为回忆 ID，客户端保留该 ID，不再重新分配。需部署 `generate-memory-v2` 和
`recover-guest-generation`；无需新增 migration、环境变量或 Nginx 改动，不改生成/扣次事务。

客户端修复需更新 App 才生效：有待上传的回忆、收藏、删除、图片、次数迁移或可迁移学习记录时
阻止退出登录；删除匿名回忆同时清理迁移队列。收藏操作在发请求前持久化，使用独立操作 ID
串行上传，旧响应只确认对应操作，不覆盖新的选择。缓存与云端的收藏差异不再直接上传。
刷新时合并待同步操作和请求期间的新修改，删除标记持续挡住旧响应，保留新生成回忆和已加载图片。

本地回归覆盖旧版待同步记录解码、快速收藏/取消、旧账号响应、刷新期间收藏/删除/新增、
匿名删除后登录合并、同步失败后的退出拦截，以及匿名生成重放/恢复使用同一 ID。
离线测试不替代 staging 真机的断网、重启与多设备验证。
