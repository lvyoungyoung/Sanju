# Staging 实例切换（2026-11-02）

## 最新目标：PG15 替代实例

用户已改选 `spb-bp112jga6hk29sgb`（杭州、PG15、2C2G），不再迁入下文的 PG17 实例。
新实例的 API 密钥和 postgres 密码保存在独立忽略文件 `.env.staging-switch.next.local`，没有复用前一目标的密码。
已在获批单个 `/32` 临时数据库白名单下完成事务性试导入及回滚，验证 30 张业务表、95 个业务函数（包括 SECURITY DEFINER）、7 条 Storage 策略、10 条语言配置及 2 个空私有 bucket。
额外检查购买 RPC 的 anon/authenticated 禁止调用、service_role 可调用、RLS 及合成 SQL 交易的加次数和重复幂等，合成账号与流水全部回滚，没有真实购买。早期数据库预演的临时白名单已恢复；后续 HTTPS 初始化另外使用了用户手动添加的 Web 白名单，收尾状态见下文。

准备的可复现基线位于 `supabase/bootstrap/staging-20261102/`，只允许这个新空 staging 使用，不在自动 migrations 目录下。清理了 PG18 pg_dump 的 PG15 不兼容设置；排除平台定义；重置业务对象 API 角色的默认 ACL 后重放源 ACL，避免目标默认权限扩大服务端 RPC 暴露范围；Storage helper 使用 public 显式引用。manifest 固定 SQL 和 88 个现有迁移文件的 SHA-256。基线结构通过校验后才登记对应迁移版本，不能直接在空库 baseline。

**新实例已正式初始化成功。** 原生 PostgreSQL 5432 连接持续超时，最终改用新实例的 HTTPS pg-meta 管理通道：先只读核对数据库身份和空库条件，再在事务中完整预演并回滚；校验 manifest 哈希后执行同一基线并提交，最后通过独立 SQL 查询核对实际结构及空数据状态。没有关闭 TLS 证书验证，也没有扩大到全公网白名单。不能据此断定 5432 连接问题的具体根因。

正式初始化后的核对结果：30 张业务表、95 个函数（其中 66 个 SECURITY DEFINER）、88 个迁移版本、10 条语言配置、2 个私有 bucket、7 条 Storage 策略；`auth.users`、`profiles`、`memories`、`purchase_ledger` 均为 0。只迁结构和公共配置，没有复制用户数据。证据位于被 Git 忽略的 `.temp/staging-switch-20261102/https-initialization-verification.local`；完整事务响应及预演响应同目录私密保存，不含在提交中。

管理通道为 `POST /pg/query`，使用新实例自身 service_role 凭据，SQL 事务以 postgres 角色执行。版本只读接口为 `/pg/config/version`，不是 `/pg/version`。后续重新建立连接的 REST 收尾检查发生连接超时，尚未完成 REST/RLS、Storage 及客户端端到端验收，不能把数据库初始化成功等同于环境切换完成。

GitHub 提交 `334c8a8` 和 `e78f02e` 已推送；本地 27 项测试、25 个步骤通过，覆盖结构基线、部署目标隔离、可信生成端点及 19 个函数部署边界。GitHub staging Secrets、客户端 key/独立持久化空间、Auth 配置、函数及运行密钥、代理上游仍需切换，旧 staging 与 production 保持原样。

用户选择自行操作服务器。仅针对 staging 的中转配置和安全切换步骤见 `docs/staging-proxy-cutover-20261102.md` 与 `deploy/nginx/sanju-staging-upstream.conf.example`；后端未就绪前不要按该文档切流。
初始化收尾已移除本次临时加入的 `153.34.233.231/32` 和 `223.104.4.35`。通过控制面重新回读确认 DB 白名单为 `127.0.0.1,100.64.0.0/10`，Web 白名单为 `127.0.0.1`，与原值一致。没有遗留本次临时开放项；后续联调需要另行按实际出口添加最小范围 Web 白名单。

## 历史：已放弃的 PG17 目标

以下记录对应先前的 `spb-kjnhpxun1ahyip6o`，不代表当前 PG15 替代实例的状态，也不能复用其中的目标凭据。

- 新实例：`spb-kjnhpxun1ahyip6o`，杭州，名称 `Sanju_testing`。
- 已通过阿里云 `GetSupabaseProject` 只读确认状态为 `running`，公网地址为 `https://spb-kjnhpxun1ahyip6o.supabase.opentrust.net`。
- 从空用户数据开始，不迁移账号、照片、收藏、学习记录或旧任务。保留旧 staging 供回退，production 不变。
- 当前仅准备代码及部署目标校验，**尚未初始化新库、部署函数、修改 GitHub Secrets、切换 Nginx 或更新客户端 key**。`api-staging.sanju.cc` 仍不能视为已连接新实例。
- 已自动取得新实例 anon/service_role key 并存入被忽略的本地文件；Dashboard 密码、新库 postgres 密码和旧库 postgres 密码分字段保管，不在日志、文档或 Git 中记录。新实例 `/auth/v1/settings` 只读检查 HTTP 200。
- 新旧数据库 TCP 连接均超时，尚未进入密码校验。本机公网 IP 不在对应数据库白名单中；只准备临时加入单个 `/32` 的方案，待用户确认后执行并在操作结束时恢复。没有开放整个公网、修改 production 或尝试猜测其他密码。现有 ECS 的 SSH 密钥访问未通过，未更改服务器登录设置。

### 已完成只读导出，初始化因平台能力阻塞

- 用户随后明确批准将 `153.34.233.231/32` 临时加入新旧数据库白名单。已连接并验证两个数据库密码；旧库 PostgreSQL 15.8，新库 PostgreSQL 17.5。
- 旧库有 30 张业务表，迁移历史 88 项与仓库文件完全一致；已导出纯 public 结构（包含此前缺失的购买事务定义）、7 条 Storage policy、10 条公共语言能力配置和 memories/avatars 两个 bucket 的配置元数据。没有导出用户行、账号、照片、流水或 Storage 对象。
- 原始结构包含平台 extensions 定义；准备的导入包已排除平台扩展函数/角色、public schema 创建及全体用户 CREATE 权限授予，不覆盖新实例自带扩展。原始快照及尚未验收的导入包仅保存在被 Git 忽略的 `.temp/staging-switch-20261102/`，未作为可发布基线提交。
- 对新库进行了 `--single-transaction` 的试导入，遇到 `SECURITY DEFINER functions are not allowed`，详情为 `adbpg_enable_security_definer is disabled`。现有 66 个函数需要该语义，不能通过去掉 SECURITY DEFINER 来迁移，否则会改变权限及事务行为。
- 试导入失败时事务已回滚，没有正式初始化业务结构。新实例 postgres 不是超级用户，对该参数的 SET 权限检查为 false；pg_settings 未返回可管理的该参数条目。当前 CLI 没有找到 Supabase 项目的对应参数接口。需要阿里云确认该实例是否可开启此能力及官方操作方式，不能自行绕过。
- 所有临时白名单窗口均已关闭，并使用 `GetSupabaseProject` 回读验证新旧两个项目的 DBSecurityIpList 和 Web SecurityIpList 与操作前一致。production 没有查询、部署或修改。当前未部署 Edge Functions、未切代理、未变更客户端 key 或 GitHub Secrets，不能开始新环境功能测试。

## 历史凭据准备

先前 PG17 目标使用 git 忽略且权限为 600 的 `.env.staging-switch.local`；当前 PG15 目标只使用 `.env.staging-switch.next.local`。不要通过聊天或命令行参数传递秘密，不要混用两个实例的 anon key、service_role key、数据库密码及连接串。旧 staging 仅提供数据库连接用于纯结构导出，不使用 production 数据库地址。阿里云控制面凭据使用本机已有配置，无需复制到文档。

## 初始化前的基线缺口

仓库第一份迁移直接引用 `profiles`，没有从零创建全部基础业务表；`docs/backend-release-process.md` 还记录 `confirm_purchase_atomically(uuid,text,text,integer)` 原始定义缺失。因此不能在空库直接 `apply`，也不能 `baseline` 后声称初始化成功。

先从旧 staging 导出并审查纯结构、RPC、RLS、权限、触发器、扩展及必要的公共配置种子。不复制 `auth.users`、用户业务行、购买流水、Storage 对象或任务。特别检查引用具体角色/owner、扩展、Storage bucket/policy、Auth 新用户触发器与初始次数、security definer 搜索路径及 EXECUTE 权限。补齐可复现基线和测试后再导入新库；迁移历史只登记目标库实际具备的版本，不能盲目修复全部版本为 applied。

## 安全切换顺序

1. 只读核对新库和旧 staging 的结构，补齐基线并本地验证。
2. 初始化新库，配置 bucket、Auth（匿名、邮箱、Apple 登录及重定向）和 Edge Function 环境变量。新实例自带的 Supabase key/URL 必须使用新实例值，不能照搬旧实例的内置变量。
3. 更新 GitHub **staging** environment 的项目 ID、API URL、service_role key、数据库密码；production Secrets 不变。代码中的两个 workflow 已将 staging 校验目标更新为新 ID，在旧 Secrets 未更新前应拒绝部署而不是落到旧实例。
4. 初始化验证通过后部署 `scripts/edge-functions.txt` 内全部函数；保留 DeepSeek → MiMo → Kimi 和现有朗读、图片审核配置。检查出公网与访问白名单，不自动扩大数据库访问范围。
5. 新实例直连验收 Auth、REST/RLS、Storage、匿名/登录生成及恢复、朗读、收藏和删除。购买只验证接口/事务，不触发真实购买。
6. 切换 ECS 上 **staging** Nginx 的 upstream、Host 与 TLS SNI 到新实例，先校验配置再平滑重载；production vhost 不变。更新客户端 staging anon key。
7. 新实例必须使用独立的客户端持久化命名空间，即使仍访问相同代理域名。隔离旧 session、待同步队列、匿名迁移状态和本地内容，避免将旧测试数据自动写入空库；不能只换 anon key。
8. 安装新测试包后通过代理再验收。旧测试包缓存/session 不保证可用，应明确退出旧账号或使用隔离测试安装。

## 回退

未验收前保留旧实例和旧代理配置；发生故障时只回退 staging 的代理、部署目标、key 与客户端命名空间，不能将新库生成的待同步任务发送旧库，也不修改 production。

这次切换本身没有新增 SQL migration；新库现已通过专用基线完成基础结构和 88 个现有迁移版本的初始化，不需要再次运行该空库初始化包。后续新增迁移仍走正常发布流程。

## 本地准备验证

`deno test --no-lock --allow-read --allow-run=/bin/bash scripts/tests/staging-bootstrap.test.ts scripts/tests/staging-instance-switch.test.ts scripts/tests/generation-endpoint.test.ts scripts/tests/edge-deployment-boundaries.test.ts`：27 项测试、25 个步骤全部通过。覆盖基线哈希与权限、当前新实例使用 DeepSeek、旧实例过渡识别、HTTP/伪造子域名不被信任、两个 workflow 的 staging/production 隔离，以及 staging 部署拒绝旧实例和 production。这些是本地模拟与结构检查，不调用真实模型或 production。`git diff --check` 通过。本次没有跑 Swift 修改的 Xcode 构建，新环境的客户端端到端验收仍待完成，不能把本地检查或数据库初始化等同于切换完成。
