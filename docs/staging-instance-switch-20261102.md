# Staging 实例切换（2026-11-02）

## 目标与状态

- 新实例：`spb-kjnhpxun1ahyip6o`，杭州，名称 `Sanju_testing`。
- 已通过阿里云 `GetSupabaseProject` 只读确认状态为 `running`，公网地址为 `https://spb-kjnhpxun1ahyip6o.supabase.opentrust.net`。
- 从空用户数据开始，不迁移账号、照片、收藏、学习记录或旧任务。保留旧 staging 供回退，production 不变。
- 当前仅准备代码及部署目标校验，**尚未初始化新库、部署函数、修改 GitHub Secrets、切换 Nginx 或更新客户端 key**。`api-staging.sanju.cc` 仍不能视为已连接新实例。
- 已自动取得新实例 anon/service_role key 并存入被忽略的本地文件；Dashboard 密码、新库 postgres 密码和旧库 postgres 密码分字段保管，不在日志、文档或 Git 中记录。新实例 `/auth/v1/settings` 只读检查 HTTP 200。
- 新旧数据库 TCP 连接均超时，尚未进入密码校验。本机公网 IP 不在对应数据库白名单中；只准备临时加入单个 `/32` 的方案，待用户确认后执行并在操作结束时恢复。没有开放整个公网、修改 production 或尝试猜测其他密码。现有 ECS 的 SSH 密钥访问未通过，未更改服务器登录设置。

## 凭据准备

填写 git 忽略且权限为 600 的 `.env.staging-switch.local`，不要通过聊天或命令行参数传递秘密：新实例 anon key、service_role key、数据库密码及连接串；旧 staging 仅提供数据库连接用于纯结构导出。不要使用 production 数据库地址。阿里云控制面凭据使用本机已有配置，无需复制到文档。

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

这次切换本身没有新增 SQL migration；新库仍需要补齐基础结构和现有迁移/配置，不能将“没有新增迁移”理解为无需数据库初始化。

## 本地准备验证

`deno test --no-lock --allow-read --allow-run=/bin/bash scripts/tests/staging-instance-switch.test.ts scripts/tests/generation-endpoint.test.ts scripts/tests/edge-deployment-boundaries.test.ts`：24 项测试、23 个步骤全部通过。覆盖新实例使用 DeepSeek、旧实例过渡识别、HTTP/伪造子域名不被信任、两个 workflow 的 staging/production 隔离，以及 staging 部署拒绝旧实例和 production。`git diff --check` 通过。尚未跑本次 Swift 修改的 Xcode 构建或新实例真实写入验收，不能把这些本地检查等同于切换完成。
