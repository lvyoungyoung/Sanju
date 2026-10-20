# Client Environments

客户端通过 bundle 内的 plist 选择 Supabase 环境：

- Debug: 使用 `三句/Config.staging.plist`
- Release/App Store: 使用 `三句/Config.plist`

`STAGING` 编译条件目前只加在 Debug build configuration 上，所以 Xcode 直接 Run 到真机时会连接 staging；Archive 上传 TestFlight 或 App Store 时仍然连接 production。

## 当前地址

- staging: `https://api-staging.sanju.cc`
- production: `https://api.sanju.cc`

注意：客户端只允许放 `anon`/publishable key，不能放 `service_role` key。

## 当前连接方式：恢复 ECS 中转（2026-10-20）

按用户提出的备案相关要求，客户端已从 Supabase 直连恢复为自有 API 域名中转：

- staging：App → `api-staging.sanju.cc` → `spb-bp1364k407p37qn7.supabase.opentrust.net`
- production：App → `api.sanju.cc` → `spb-bp103246ivn7q0nl.supabase.opentrust.net`

Auth、REST、Storage、Edge Functions 和云端朗读均使用对应环境的 API 中转入口。此次只恢复客户端入口，不修改在线 Nginx、Web/数据库白名单或业务逻辑；无需部署云函数或新增数据库迁移。此前已发布的直连客户端需要安装新构建才会切回中转。

保留 `SupabaseEnvironment.persistenceNamespace` 的地址别名兼容，翻卡历史、AI 解析及语音缓存沿用相同的本地存储标识。它只决定缓存键，不会把请求切回直连。

恢复中转后的验证：两个环境的 `/auth/v1/settings` 使用原有公开密钥均返回 HTTP 200；Debug 模拟器构建与 Release arm64 模拟器构建通过，逐一检查两个构建内的正式/测试 plist，均为上述中转地址。配置文件除 `SupabaseURL` 外的字段保持一致。

## 历史记录：Supabase 直连试验（2026-10-20，已恢复中转）

当时客户端直接通过 HTTPS 请求对应项目的 Auth、REST、Storage 和 Edge Functions，不经过 ECS/Nginx API 中转。图片上传和下载使用相对 Storage 路径，也随配置切换。AI 调用、购买校验和额度处理仍由原有云函数负责。以下记录仅说明当时排查和验证过程，不代表当前客户端入口。

本地翻卡历史、AI 解析缓存和语音缓存继续使用切换前的环境标识，避免仅因网络地址变化而丢失缓存或未同步反馈。这个标识只用于本地存储，不用于请求地址；正式和测试环境仍然隔离。

直连需要阿里云项目的 Web 白名单允许客户端网络访问。Web（80/443）与数据库（5432）白名单可以分别修改；仅修改 Web 时应显式设置 `UpdateWeb=true`、`UpdateDb=false`，两项默认均为 true。数据库白名单无需因客户端直连而放开。参见 [阿里云 API 文档](https://www.alibabacloud.com/help/en/analyticdb/analyticdb-for-postgresql/developer-reference/api-gpdb-2016-05-03-modifysupabaseprojectsecurityips)。

此次无需部署云函数或新增数据库迁移，也无需修改 Nginx。2026-10-20 已依次对 staging、production 设置 `SecurityIPList=0.0.0.0/0`、`UpdateWeb=true`、`UpdateDb=false`，并通过 `GetSupabaseProject` 回读确认两边的 `DBSecurityIpList` 与修改前逐字一致。

### 直连超时排查与验证

修改前，两个项目的 Web 白名单仅包含 ECS 和少量固定出口 IP；本机绕过代理访问直连域名的 443 端口均超时，而 staging 中转返回预期的未认证 `401`。DNS 解析正常。仅放开 Web 白名单后，两个环境使用客户端原有公开密钥直连 `/auth/v1/settings` 均返回 `200`，确认此次阻断由 Web 白名单引起。

staging 使用新建临时匿名账号，实际验证通过：登录、获取当前用户、刷新会话、读写个人资料、读取回忆列表、测试图片上传/下载/删除、生成接口缺图校验、购买接口未认证校验、空任务恢复和语音流。`Hello.` / `Mia` 语音首段约 0.75 秒收到，完整接收 46,080 字节 PCM 和 `done` 事件；测试图片与临时账号均已删除。此耗时仅是单次本机测量，不代表所有用户网络的性能。

正式环境已验证 Web 白名单、数据库白名单保持不变及认证接口直连；没有对真实用户数据执行写入，也没有执行付费图片生成。发布前仍应在真机 Wi-Fi/蜂窝网络完成日常流程验收。

## 中转入口兼容

`https://api-staging.sanju.cc` 和 `https://api.sanju.cc` 的既有代理入口继续供旧版与恢复中转后的新构建使用。此次变更不删除服务器或修改 Nginx；官网、部署任务及服务器其他用途不受影响。反向代理结构见 `deploy/nginx/sanju-api-proxy.conf.example`。已上线的旧客户端字段兼容迁移继续保留，不回滚。
