# 三句项目交接说明

这份文档用于在切换到新的 AI 对话、换设备、或让其他工程协作者接手时，快速理解“三句”的产品目标、客户端结构、后端设计、核心业务链路和发布约束。

客户端功能核对：2026-10-09。以下早期架构说明需结合本节及较新的专项文档阅读。

当前学习入口已恢复为底部“收藏”Tab：页面顶部展示今日待学、今日已学和开始学习按钮，下方直接展示收藏句子列表。保留本地/云端收藏学习进度、当天再学一遍、已学次数、朗读播放状态和长按取消收藏。自定义学习主题的客户端创建、详情、匹配设置、主题地图及 AppModel 状态/操作已移除；收藏统计不再读取主题列表。

“收藏”Tab 的原生角标显示今日待学数量，数量为 0 时隐藏，启动时无需先进入收藏页。“翻一翻”卡片右上角显示收藏星标，点击或双击卡片均切换收藏/取消收藏；星标读取实时状态，并显示短暂“已收藏”或“已取消收藏”反馈，底部仅提示“双击收藏”，不再显示左右滑动说明。收藏沿用原有持久化和登录用户同步/失败重试，不推进翻看队列，也不增加填空学习记录。

收藏页顶部改为单行紧凑学习统计和按钮，空间不足或大字体时可自动换行。句子卡片左侧显示 68pt 缩略图，右侧只显示完整英文和朗读按钮，列表不展示中文、日期和已学次数。照片/句子可进入原回忆详情，长按仍可取消收藏；学习进度和统计数据不删除。缩略图按需共享原有图片下载，后台缩小到 256px 并缓存解码结果，支持图片晚到及账号变化时刷新。

回忆的按时间照片列表和照片主题详情统一使用较小的拍立得相纸样式，照片为直角，白色相纸为 4pt 小圆角，上方和左右为 6pt 白边，底部为 24pt 白边，旋转幅度为 1.25 到 2.75 度，带轻微水平偏移和阴影。同一行统一尺寸和垂直中心，不再随机缩放或纵向偏移。角度和水平偏移由回忆 ID 稳定生成，刷新及重启不会重新随机；旋转后的图片限制在各自布局区域内，避免遮挡日期、相邻照片或底部按钮。按时间列表保留日期分组；照片主题详情不显示照片数量和日期标题，所有照片连续排列。主题列表的圆角堆叠封面不变。时间顺序和分页加载、点击详情、长按删除及主题内翻一翻范围不变。

本次仅调整客户端，不删除数据库中的历史主题/进度或后端接口，不需要迁移或 Edge Function 部署。生成仍保留两组三句、句子分类、表达用途和后台向量生成；“回忆”中的照片分类与“翻一翻”也保留。

## 1. 产品概览

“三句”是一款 iOS 英语学习 App。用户选择一张对自己有意义的照片，App 用 AI 生成三句英文描述和对应中文翻译，保存为一条“回忆”。用户可以收藏想反复练习的句子，并在“收藏”里通过选词填空的方式复习。

核心产品逻辑：

- 一张图片生成三句英文描述，每句有中文翻译。
- 生成结果保存为“回忆”，可以在回忆列表和详情页查看。
- 每句可以收藏，收藏后的句子进入学习系统。
- 学习方式是选词填空，优先挖空介词等适合练习的词。
- 学习进度按天结算，默认每天最多激活 30 句新学习内容；用户可以再次复习当天已学过的句子。
- 未登录用户可以生成和本地保存，登录后同步到云端。
- 邮箱登录/注册/重置密码是当前唯一登录方式，Apple 登录已移除。
- 用户可购买生成次数，购买确认在后端原子化处理。

## 2. 代码仓库结构

仓库：`https://github.com/lvyoungyoung/Sanju`

主要目录：

- `三句/`：iOS 主 App 源码。
- `三句小组件/`：桌面小组件扩展。
- `三句Tests/`：当前已有 CloudSync 相关单元测试。
- `supabase/functions/`：阿里云 AnalyticDB Supabase Edge Functions 源码。
- `supabase/migrations/`：数据库表结构、RPC、RLS 和修复 SQL migration。
- `.github/workflows/`：GitHub Actions，负责部署 Edge Functions 和数据库 migration。
- `scripts/`：部署、检查和兼容性测试脚本。
- `docs/`：项目文档。
- `deploy/nginx/`：ECS Nginx 反向代理配置示例。

重要文档：

- `docs/backend-release-process.md`：后端发布流程。
- `docs/database-migrations.md`：数据库 migration 发布流程。
- `docs/client-environments.md`：客户端 staging/production 环境说明。
- `docs/old-client-compatibility.md`：旧客户端兼容性测试说明。
- `docs/release-checklist.md`：上线检查清单。
- `docs/github-self-hosted-runner.md`：GitHub self-hosted runner 说明。
- `docs/ECS入口反向代理RDS-Supabase方案.md`：ECS 反向代理方案。

## 3. 客户端架构

客户端是原生 SwiftUI iOS App。

核心文件：

- `三句/AppModel.swift`：全局状态和核心模型定义。
- `三句/AppModel+Auth.swift`：邮箱登录、注册、重置密码、匿名 session、退出登录、删除账号、访客次数迁移。
- `三句/AppModel+Memories.swift`：生成、回忆、本地/云端同步、收藏、恢复生成任务。
- `三句/AppModel+Persistence.swift`：本地持久化、图片缓存、Keychain/UserDefaults 读写。
- `三句/AppModel+Purchases.swift`：StoreKit 购买与后端确认。
- `三句/AppModel+RateLimiting.swift`：客户端侧频率限制。
- `三句/AppModel+LearningReminder.swift`：学习提醒设置。
- `三句/SupabaseService.swift`：所有 Supabase HTTP/RPC/Storage/Edge Function 调用。
- `三句/SupabaseModels.swift` 和 `三句/SupabasePayloads.swift`：Supabase 请求/响应模型。
- `三句/CloudSyncManager.swift`：云同步计划与本地/远端回忆合并逻辑。
- `三句/MemoryIdentity.swift`：回忆内容身份匹配逻辑。
- `三句/PurchaseManager.swift`：StoreKit 产品加载、购买、交易状态。
- `三句/NetworkStatusMonitor.swift`：网络状态监控。
- `三句/LocalRateLimiter.swift`：本地频率限制工具。
- `三句/L10n.swift`：国际化入口。
- `三句/DesignSystem.swift`：统一设计 token。

主要页面：

- `三句/MainTabView.swift`：底部 tab。
- `三句/NewLearningView.swift`：选择图片、生成三句、恢复生成任务。
- `三句/MemoriesView.swift`：回忆列表。
- `三句/MemoryDetailViews.swift` 和 `三句/MemoryDetailComponents.swift`：回忆详情。
- `三句/FavoritesView.swift`：收藏页和学习入口。
- `三句/SentenceStudySessionView.swift`、`三句/SentenceStudyQuestion.swift`、`三句/SentenceStudyComponents.swift`：学习流程。
- `三句/ProfileView.swift`：我的页面、购买、生成偏好、学习提醒、关于我们。
- `三句/SignInView.swift`：登录/注册/重置密码。

## 4. 客户端环境

客户端通过 plist 选择 Supabase 环境：

- Debug：`三句/Config.staging.plist`
- Release/App Store/TestFlight：`三句/Config.plist`

当前配置：

- staging API：`https://spb-bp1364k407p37qn7.supabase.opentrust.net`
- production API：`https://api.sanju.cc`

注意：

- `https://api.sanju.cc` 是 ECS Nginx 反向代理到阿里云 Supabase 的入口，用于规避部分网络下直接访问 Supabase 域名不稳定的问题。
- 客户端只能放 Supabase publishable/anon key，绝不能放 service_role key。
- TestFlight 当前连 production，而不是 staging。

## 5. 核心数据模型

客户端核心模型在 `AppModel.swift`：

- `MemoryEntry`：一条回忆，包含图片、创建时间、远端图片路径、同步状态、三句句子。
- `SentenceRecord`：一句英文/中文，以及是否收藏。
- `UserProfile`：用户资料，当前包含昵称、邮箱、appleUserID 字段。Apple 登录已移除，但字段仍用于兼容历史结构。
- `SentenceStudyProgress`：云端学习进度。
- `LocalSentenceStudyProgress`：本地学习进度，匿名用户使用；登录后会合并到云端。
- `PendingGeneratedMemoryImage`：生成过程中断后的恢复凭据，包含图片、guestJobID/clientRequestID、开始时间。
- `PendingFavoriteChange`：收藏同步失败后的重试队列。
- `PendingMemoryDeletion`：删除回忆同步失败后的重试队列。
- `PendingGuestCreditMigration`：访客次数迁移到登录账号的待处理状态。

后端主要表和 RPC 由 `supabase/migrations/*.sql` 管理。不要手动修改已经执行过的 migration，修复时新增更晚的 migration。

## 6. 认证与账号逻辑

当前认证方式：

- 邮箱登录。
- 邮箱注册。
- 邮箱验证码重置密码。
- 匿名 session 用于未登录用户的生成、本地记录和访客次数。

重要行为：

- 第一次安装默认发放 5 次生成机会。
- 新注册账号本身不赠送次数。
- 用户未登录时使用匿名 session，匿名 profile 会存在云端，用来关联访客可用次数和生成 job。
- 用户注册/登录后，会把本地未同步回忆、收藏、学习记录、访客可用次数合并到登录账号。
- 退出登录时会清空本地回忆和本地可用次数，云端账号和数据保留。
- 删除账号时会删除云端账号、云端数据、本地回忆、本地收藏和未使用次数。
- 如果正在生成或正在同步本地修改到云端，客户端会阻止退出登录/删除账号，避免数据丢失。

密码重置：

- 客户端调用 Supabase Auth recovery OTP。
- 邮件由 Supabase SMTP 配置发送。
- 验证码错误会提示更友好的中文文案。

## 7. 图片生成链路

入口：`NewLearningView` -> `AppModel.generateMemory(from:)` -> `SupabaseService.generateMemorySentences(...)` -> Edge Function `generate-memory-v2`。

客户端处理：

1. 用户选择图片。
2. 客户端压缩两份图：
   - `analysisImageData`：发送给 MiMo/Kimi 理解图片。
   - `memoryImageData`：保存为回忆图片。
3. 生成前创建 `PendingGeneratedMemoryImage`，记录：
   - `guestJobID`：匿名用户使用。
   - `clientRequestID`：登录用户和匿名用户都可用于恢复。
   - `previousMemoryIDs`：用于旧逻辑差异检测。
   - `imageData`：恢复 UI 和保存回忆使用。
4. 调用后端生成。
5. 成功后写入本地 `memories`，更新可用次数，清理 pending。
6. 如果请求超时、App 进后台、锁屏、网络中断，客户端会走恢复逻辑，不应重复生成。

后端 `generate-memory-v2` 的职责：

1. 验证 JWT。
2. 检查 profile 和可用次数。
3. 检查用户是否因图片违规被临时禁用。
4. 调用 `moderate-image-v1` 做图片审核。
5. 图片审核明确高风险才拦截；审核接口错误或 10 秒超时会放行。
6. 获取生成并发槽，当前并发上限为 `GENERATION_CONCURRENCY_LIMIT = 50`。
7. 优先调用 MiMo。
8. MiMo 失败或响应格式不可解析时 fallback 到 Kimi。
9. 通过数据库 RPC 原子化完成：
   - 写 generation job。
   - 写 memory。
   - 写 memory sentences。
   - 扣减 available_generations。
10. 返回 memory 和 remainingCredits。

重要原则：

- 只有阿里云图片审核明确返回违规时，才给客户端 `generation_policy_violation`。
- 不再根据 MiMo/Kimi 文本里是否出现“政策/违规”等字样判断图片违规。
- 如果 MiMo/Kimi 都失败，不能扣次数，也不能留下半成品 memory。
- 登录用户通过 `clientRequestID` 恢复生成结果。
- 匿名用户通过 `guestJobID` 和 `clientRequestID` 恢复生成结果。
- 一轮完整恢复仍然没有结果时，客户端会清理 pending，避免每次打开 App 都进入幽灵恢复。

## 8. 图片审核与违规封禁

图片审核函数：`supabase/functions/moderate-image-v1/index.ts`

当前逻辑：

- 使用阿里云图片审核增强版。
- 函数先把图片上传到阿里云临时 OSS，再调用审核接口。
- 只有 high risk 或严重标签才拦截。
- 审核接口错误或超时不阻断生成。
- `generate-memory-v2` 对审核函数最多等待 10 秒；超时放行。

违规封禁：

- 表结构/RPC 在 `20260501000000_generation_violation_bans.sql` 等 migration 中。
- 策略：24 小时内 20 张图片触发高风险审核不通过，会禁用生成 24 小时。
- 环境变量 `GENERATION_VIOLATION_BAN_ENABLED=false` 可以只关闭累计封禁机制；单张高风险图片仍会被拦截。
- 上线前 `IMAGE_MODERATION_DEBUG` 应为 `false`，避免把审核内部细节返回客户端。

## 9. 生成恢复与网络异常

客户端关注点：

- 无网络时，不允许选择图片，上传区域置灰并显示“请连接网络”。
- 无网络时，不发起生成请求。
- 已经发出的生成请求如果因锁屏、切后台、网络中断导致客户端没有收到结果，会进入恢复。
- 恢复按钮只获取结果，不重新生成，避免重复扣次数。
- 如果网络恢复，客户端会自动尝试恢复 pending 生成结果。

后端关注点：

- `generation_jobs` 记录生成请求状态。
- 对同一个 `clientRequestID`，重复请求应尽量幂等。
- 生成成功和扣次数必须在数据库 RPC 中原子化完成。
- 如果 App 断线但后端成功生成，恢复接口应能找回 memory。

相关文件：

- 客户端：`NewLearningView.swift`、`AppModel+Memories.swift`
- 迁移：`20260509000000_add_generation_jobs.sql`、`20260510000000_atomic_generation_finalize.sql`、`20260510001000_finalize_generation_job_in_rpc.sql`
- 函数：`generate-memory-v2`、`recover-guest-generation`

## 10. 回忆与云同步

核心文件：

- `AppModel+Memories.swift`
- `CloudSyncManager.swift`
- `MemoryIdentity.swift`
- `AppModel+Persistence.swift`

同步原则：

- 匿名用户生成的回忆先保存在本地，并进入待迁移队列。
- 登录后本地未同步回忆会上传到云端。
- 本地收藏状态、删除操作、学习记录都有 pending 队列，失败后下次同步重试。
- 从云端拉回大量回忆时，先加载元数据，再分批水合图片。
- 图片水合只合并当前 memory 的 imageData，不应该用旧数组快照覆盖当前内存状态。
- 退出登录前如果存在正在同步的本地修改，会阻止退出。

常见坑：

- 不要在下载图片期间保留旧 `memories` 整体快照再写回，否则可能覆盖用户刚做的删除或收藏。
- 不要在同步未完成时清空本地数据。
- 登录后的本地学习记录合并到云端后，要刷新学习计数，否则 UI 会短暂显示不准。

## 11. 收藏与学习系统

入口：

- 收藏页：`FavoritesView.swift`
- 学习流程：`SentenceStudySessionView.swift`、`SentenceStudyQuestion.swift`、`SentenceStudyComponents.swift`

学习范围：

- 当前主要学习“收藏”的句子。
- 未登录用户也有本地学习记录；登录后合并到云端。
- 学习记录需要上云。

学习队列：

- 每天最多激活 30 句新学习内容。
- 学完当天新内容后，用户可以“再学一遍”当天已学内容。
- 再学一遍会打乱顺序，不影响第二天学习。
- “收藏”Tab 使用原生角标显示今日待学数量，没有待学不显示。

学习方式：

- 选词填空。
- 默认聚焦第一个空格，点击下方单词填入。
- 正确则填入并进入下一个空格；错误则当前空格红色提示。
- 单句完成后可以朗读或下一句。
- 一轮完成后显示完成页。

挖空策略：

- 优先选择介词等有学习价值但不破坏句子理解的词。
- 长句要避免空格集中在前半句，应尽量分布均匀。
- 当天第二次学习也按同一逻辑生成题目，但顺序可打乱。

云端相关 RPC：

- `get_sentence_study_queue`
- `count_sentence_study_queue`
- `record_sentence_study_result`
- `merge_local_sentence_study_progress`
- `count_sentence_studied_today`
- `count_sentence_study_reviewable_today`
- `get_sentence_study_today_review_queue`

## 12. 购买与次数

客户端：

- `PurchaseManager.swift`
- `AppModel+Purchases.swift`
- `ProfileView.swift`

后端：

- `supabase/functions/confirm-purchase/index.ts`
- RPC：`confirm_purchase_atomically`

产品：

- 当前商品：
  - `com.yanglv.sanju.credits200`：200 次
  - `com.yanglv.sanju.credits365`：365 次

购买安全原则：

- 客户端 StoreKit 成功后，把 transactionID/productID 交给后端。
- 后端用 App Store Server API 验证 transaction。
- 后端校验 bundleID、productID、transactionID、appAccountToken。
- 后端 RPC 原子化处理购买，避免重复发放。
- 如果同一 transaction 已处理，后端返回已有余额和 alreadyProcessed。

环境变量：

- `APP_STORE_CONNECT_ISSUER_ID`
- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_PRIVATE_KEY`
- `APP_STORE_BUNDLE_ID`
- `STOREKIT_PRODUCT_CREDITS_JSON`

注意：

- 私钥 `.p8` 内容如果放环境变量，可使用 `\n` 转义；函数里会 `replace(/\\n/g, "\n")`。
- 不要把购买发放逻辑放在客户端。

## 13. Edge Functions

当前函数清单在 `scripts/edge-functions.txt`：

- `generate-memory-v2`：生成三句、图片审核、MiMo/Kimi fallback、扣次数、写 memory。
- `create-study-scene`：为用户自定义学习场景生成语义向量，并建立与已有句子向量的匹配关系。
- `moderate-image-v1`：阿里云图片审核。
- `recover-guest-generation`：匿名生成任务恢复。
- `confirm-purchase`：购买验证和次数发放。
- `delete-account`：删除账号和关联数据。
- `migrate-guest-credits`：访客可用次数迁移到登录账号。
- `cleanup-guest-generation-jobs`：清理过期匿名生成 job 和临时图片。

所有函数源码都必须以 GitHub 仓库为准，不要只在阿里云网页编辑器里改。

## 14. 数据库与 migration

数据库使用阿里云 AnalyticDB Supabase。

当前项目：

- production project id：`spb-bp103246ivn7q0nl`
- staging project id：`spb-bp1364k407p37qn7`
- region：`cn-hangzhou`

重要原则：

- 所有表结构、RPC、RLS 变更都写入 `supabase/migrations/*.sql`。
- 已执行过的 migration 不修改，新增更晚文件修复。
- 日常流程是先 staging apply，再 production apply。
- 后端函数依赖新表/RPC 时，先跑 SQL，再部署函数。
- 历史 migration 已经 baseline 过，之后只关注新增 migration。

数据库发布工作流：

- GitHub Actions：`Backend Database`
- 脚本：`scripts/supabase-db-migrations.sh`
- 使用阿里云版 Supabase CLI，不是官方 Supabase CLI。

## 15. 部署与环境

GitHub Actions：

- `Backend Functions`：检查并部署 Edge Functions。
- `Backend Database`：执行 SQL migrations。

部署机器：

- Edge Function 和 DB migration 部署使用 ECS self-hosted runner。
- runner label：`self-hosted, linux, x64, aliyun-ecs`
- 原因：GitHub hosted runner 到阿里云 Supabase 有时 TCP 连接阶段超时。

Secrets：

- `SUPABASE_API_URL`
- `SUPABASE_API_KEY`，service_role key
- `SUPABASE_PROJECT_ID`
- `SUPABASE_DB_PASSWORD`
- `ALIYUN_ACCESS_TOKEN`，格式 `<AccessKeyID>|<AccessKeySecret>`

不要提交到仓库：

- service_role key
- SMTP 密码
- 阿里云 AccessKey Secret
- App Store Connect 私钥原文

## 16. ECS 与域名

ECS 当前承担：

- 官网 `sanju.cc` / `www.sanju.cc`
- API 反向代理 `api.sanju.cc`
- GitHub Actions self-hosted runner

Nginx 反向代理：

- 示例文件：`deploy/nginx/sanju-api-proxy.conf.example`
- production 客户端访问 `https://api.sanju.cc`
- Nginx 转发到 production Supabase：`spb-bp103246ivn7q0nl.supabase.opentrust.net`

证书：

- `api.sanju.cc` 当前使用 Let’s Encrypt 证书。
- 已验证 `certbot renew --dry-run` 可以自动续期。

## 17. 小组件

目录：`三句小组件/`

相关客户端文件：

- `MemoryWidgetSnapshotStore.swift`
- `AppModel+Persistence.swift`

逻辑：

- App 持久化回忆后更新小组件 snapshot。
- 小组件从 App Group 读取快照。
- iPad 上以 iPhone 模式运行时，小组件可能表现受系统限制，暂时不作为核心支持目标。

## 18. 本地持久化与安全

本地存储：

- Keychain：Supabase session、首次安装赠送标记、待迁移状态等敏感/半敏感状态。
- UserDefaults：偏好、本地状态、pending 队列等。
- 文件系统：本地图片缓存。
- App Group：小组件快照。

安全：

- Keychain 使用显式 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`。
- `PrivacyInfo.xcprivacy` 已添加，声明 UserDefaults required reason API。
- 后端 raw response 不应直接展示给用户；生产环境只给通用错误文案。

## 19. 国际化

国际化入口：

- `L10n.swift`
- `zh-Hans.lproj/Localizable.strings`
- `en.lproj/Localizable.strings`

现状：

- 已经开始把部分文案走 `L10n.string(key, fallback)`。
- 仍有一些中文硬编码分散在业务和 UI 里。
- 如果要正式国际化，应优先整理登录、生成、学习、购买、错误提示、关于页等用户可见文案。

## 20. 频率限制与用户提示

客户端已有本地限制：

- 登录密码错误：连续 3 次后 1 分钟内禁止登录。
- 忘记密码：5 分钟内超过 3 次提示频繁。
- 生成偏好切换：有 debounce，并限制 1 分钟内修改超过 10 次后 5 分钟内禁止操作。
- 生成按钮：后端还有并发槽和违规封禁保护。

用户提示原则：

- 不暴露技术细节，例如不要显示具体限流规则。
- 频繁操作统一提示“操作频繁，请稍后再试。”
- 图片违规提示需要明确但不过度吓人：
  “这张图片暂时无法生成，请更换图片后再试。请勿发送色情、裸露、涉政等图片，否则可能导致临时禁用或账号永久封禁。”

## 21. 测试和验证

常用命令：

```bash
xcodebuild -project 三句.xcodeproj -scheme 三句 -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /private/tmp/sanju-codex-derived-data build
```

```bash
bash scripts/check-edge-functions.sh
```

```bash
node scripts/check-client-compatibility.mjs
```

production 兼容性测试需要显式允许：

```bash
SANJU_COMPAT_ALLOW_PRODUCTION=1 node scripts/check-client-compatibility.mjs
```

重要测试场景：

- 首次安装是否发放 5 次。
- 匿名生成、杀 App、恢复生成。
- 登录用户生成、锁屏、恢复生成。
- 没网时不能选图，恢复逻辑不重复生成。
- 匿名本地回忆登录后上传云端。
- 收藏失败后重试。
- 删除回忆同步。
- 本地学习记录登录后合并云端。
- 每日学习队列和再学一遍。
- 购买成功、重复确认购买、余额正确。
- 重置密码邮件和验证码。
- 删除账号清理本地和云端。
- 小组件显示。

## 22. 常见问题和坑

1. 不要把 staging 的数据库状态直接当成 production 真相。
   生产发布应通过同一份 migration apply。

2. Edge Function 和 GitHub 源码要一致。
   如果临时在阿里云网页编辑器修改，必须回写仓库，否则之后会被 GitHub Actions 覆盖。

3. 生成失败但扣次数是严重问题。
   生成、写 memory、扣次数必须在 RPC 内原子化。任何改动都要检查这个链路。

4. 锁屏/切后台不是生成失败。
   客户端可能断线，后端仍继续生成。客户端应恢复结果，而不是提示“使用人数过多”或重新生成。

5. 图片审核失败和模型失败要分开。
   只有阿里云审核明确违规才是 `generation_policy_violation`。

6. 同步期间不能退出登录。
   否则本地未同步数据可能被清空。

7. 不要在生产日志里输出用户 ID、邮箱、完整后端 raw response 或敏感配置。

8. Xcode 构建建议用 `/private/tmp/sanju-codex-derived-data`。
   避免 iCloud/FileProvider 扩展属性导致签名或小组件相关问题。

9. production TestFlight 当前连 production。
   如果要测试 staging，需要单独调整客户端环境策略。

## 23. 给新 AI 的工作建议

如果你是接手这个项目的新 AI，请先做这些事：

1. 读本文件。
2. 读 `docs/backend-release-process.md`、`docs/database-migrations.md`、`docs/client-environments.md`。
3. 用 `rg` 定位相关功能，不要凭文件名猜。
4. 修改客户端前先确认是否会影响匿名/登录两套路径。
5. 修改生成链路前先确认：
   - 是否会重复生成。
   - 是否会错误扣次数。
   - 是否能恢复锁屏/断网后的结果。
   - 是否兼容匿名和登录用户。
6. 修改数据库前新增 migration，不要改旧 migration。
7. 修改 Edge Function 后运行 `bash scripts/check-edge-functions.sh`。
8. 修改客户端后至少跑一次 `xcodebuild`。
9. 发布后端时先 staging，再 production。
10. 不要要求用户“复制保存文件”，用户和你在同一个 workspace。

## 自定义场景语义匹配

预定义分类现为 21 个相册生活场景，按句子（每句最多两个，主场景在前，第二个需要明确的句子依据）而不是照片归类，不包含“实用记录”。新目录、边界、迁移及部署步骤见 `docs/life-scene-topics.md`。迁移 `20260920001000_use_photo_life_scenes.sql` 移除旧预定义主题、清空旧句子分类，不重分历史内容；照片、句子、收藏、自定义主题和学习进度行不删除。此轮需要同步部署 `generate-memory-v2`、`recover-guest-generation`、`create-study-scene`。

用户创建“我的学习主题”时，客户端将主题名称提交给 `create-study-scene`。预定义主题使用分类 ID 精确匹配；自定义主题先由 MiMo 提取一段简短英文检索描述，再使用阿里云百炼 `qwen3.7-text-embedding` 生成 1024 维 `query` 向量；英文句子及中文翻译按 `document` 生成向量。主题仍保存原始名称，不批量改已有主题向量。意图提取复用 `MIMO_BASE_URL` / `MIMO_API_KEY`，最多等待 8 秒；缺配置、失败、格式错误或不明确时回退原名，不阻断创建。推荐分类和超出 20 个上限的创建请求不调用意图模型；此步骤不是逐句复核。意图提取本身只需更新 `create-study-scene`，无新增迁移或客户端接口。

2026-09-21 按用户要求暂时停用 AI 逐句复核，自定义主题恢复为同账号、相同向量模型、相似度 `>= 0.42` 直接收录。`20260921002000_pause_study_scene_ai_review.sql` 替换匹配 RPC 并重算已有自定义主题，保留复核历史和学习记录；旧复核 RPC 停用，旧客户端入口 `review-study-scene` 只返回零待办。客户端不再调用复核，生成函数不再启动后台复核。需先运行迁移，再部署 `generate-memory-v2`、`review-study-scene`。完整规则、历史方案和测试见 `docs/custom-study-topic-matching.md`。

- 表：`sentence_embeddings`、`study_scene_embeddings`、`study_scene_sentences`、`study_scene_sentence_reviews`。新增的复核表保存候选、输入指纹、判断原因及重试租约，不对客户端开放。
- 新生成的登录用户句子会在 `generate-memory-v2` 原子化落库后异步式地补写向量并匹配已有场景；这一步失败不会影响生成结果或可用次数。
- 第一版不回填历史句子向量，因此旧句子可能不会进入新建的自定义场景。
- 必需环境变量：`DASHSCOPE_API_KEY`、`DASHSCOPE_EMBEDDING_URL`。后者应填写百炼原生接口 `https://<WorkspaceId>.cn-beijing.maas.aliyuncs.com/api/v1/services/embeddings/text-embedding/text-embedding`；地址不内置默认值，以便和 MiMo、Kimi 的服务地址配置方式保持一致。
- 首次向量功能 migration：`20260811006000_add_semantic_study_scene_matching.sql`。历史复核 migration `20260920000000_review_custom_study_scene_matches.sql` 不修改，后续暂停迁移覆盖其行为。`create-study-scene`、匿名恢复和旧收藏学习接口保持兼容。

## 学习日与设备时区

新客户端的收藏和自定义主题学习统一使用手机当前时区的自然日。`StudyCalendar` 随 RPC 和 `create-study-scene` 请求发送 `x-sanju-study-time-zone`；后端验证时区并以服务端时间计算今日队列、计数、完成去重和下次复习日。旧客户端不传时区时仍使用北京时间，不改变接口签名和权限。匿名学习记录登录合并时也按设备时区转换。部署迁移 `20260921000000_use_device_study_time_zone.sql`，并重新部署 `create-study-scene`；详情及测试见 `docs/study-time-zone.md`。

## 启蒙难度

生成偏好仅保留启蒙（Starter）、初级、中级三档难度，默认初级，raw value 分别为 `启蒙`、`简单`、`中等`；客户端将历史 `高级` 归一为中级。启蒙每句 3–6 个词，初级每句 6–10 个词，中级每句 10–16 个词，两组句子遵循同一档难度。客户端不再提供、保存、同步或发送语言风格设置，后端固定使用自然日常口语，启蒙保持友好直接，不启用抒情。场景表达三句依次写感受、当时可能对别人说的话、发生了什么。DeepSeek、MiMo、Kimi 共用提示词。2026-10-08 试用 Gemini 模板后按用户要求恢复至接入前版本；JSON 输出格式及每句分类、表达用途字段不变，生成完成后的单轮“翻一翻”功能继续保留。

启蒙难度的历史部署需先应用 `20260921001000_add_starter_english_level.sql`。2026-10-08 移除风格设置只需更新客户端和 `generate-memory-v2`，没有新增数据库迁移。保留数据库 `profiles.language_style`，新建 profile 时客户端写固定值 `平铺直叙` 以兼容没有默认值的数据库；其他 profile PATCH 不写该字段，读取时不依赖它。旧生成请求里的 `languageStyle` 被忽略，响应格式、恢复和扣次数事务不变。旧本地偏好缓存的 `style` 字段被忽略，难度及待同步状态继续保留。`recover-guest-generation` 只恢复已生成结果，不调用模型，无需更新。

## 学习主题数量上限

学习主题数量上限为每账号 20 个，推荐分类创建的主题和自定义语义主题共用额度；收藏不计入。客户端在打开创建窗口及提交时检查缓存，后端在生成向量前预检查，`20260921003000_limit_study_scenes_to_twenty.sql` 的数据库触发器通过账号级事务锁保护最终写入（覆盖两条创建 RPC、直接插入和账号归属变更）。同名 upsert 不新增名额，删除后可继续创建，已有超过 20 个的账号不删旧主题、仅限制新增。错误码 `study_scene_limit_reached` 映射为中英文提示。部署需运行该迁移并更新 `create-study-scene`。

## 学习主题封面

迁移 `20260921004000_use_oldest_study_scene_cover.sql` 将主题列表和单主题摘要的 `cover_memory_id` 统一改为当前匹配句子所属的最早创建的回忆，时间相同按回忆 UUID 升序确定选择。以回忆创建时间为准，不读取照片拍摄时间。新增较新的回忆不会替换封面；原回忆删除或所有相关句子移出主题时递补，无匹配句子时返回 null。若后来匹配到更早的历史回忆，仍会按最早规则更新，并非持久锁定封面。已存在主题在部署后可能一次性切换到更早的照片。

本项只需运行数据库迁移，无需重新部署 Edge Function 或修改客户端；接口字段、访问权限、主题顺序、句子队列和学习统计不变。`study-time-zone.test.ts` 同时覆盖封面稳定性、时间相同的选择、移除后的递补、空主题和迁移重复执行。

## 生成任务可靠性与完整响应超时

迁移 `20260921005000_claim_generation_jobs_atomically.sql` 新增仅 service role 可调用的 `claim_generation_job`。登录请求 ID 与匿名 job ID 都通过原子插入领取执行权，重复 pending 请求返回处理中，终态直接复用或返回失败，不重置 pending。两个任务表的触发器阻止跨账号修改身份、终态回退及覆盖已完成结果，保留匿名 acknowledged 与回忆删除清空外键的合法操作。

生成函数移除事务外的完成状态/回忆 ID 重写，带请求 ID 的结果从数据库读取；失败更新只针对本账号且仍 pending 的已领取任务。finalize 响应丢失不能当作确定回滚：不删图片、不标失败，返回可恢复超时。无请求 ID 的旧登录客户端仍可生成三句，不具备新请求 ID 级别去重。pending 不自动抢占重跑，本轮没有增加后台接管或改变匿名结果 24 小时保留策略。

`generate-memory-v2` 和 `moderate-image-v1` 使用 `_shared/fetch-with-timeout.ts`，计时覆盖完整响应体读取，原单阶段 10/20/8 秒等参数不变。生成函数所有出站请求另共享 90 秒网络预算，失败标记及释放名额各有独立 5 秒清理额度。客户端识别 `generation_in_progress` 并查询旧任务。部署顺序：数据库迁移 -> 两个函数 -> 客户端；无需修改 `recover-guest-generation`。完整链路及边界见 `docs/image-generation-flow.md`。

## 回忆按主题浏览

“回忆”顶部提供“按时间 / 按主题”，默认按时间，保留原日期分组照片网格。“按主题”使用图片本身的 AI 分类，不再聚合 `SentenceRecord.learningTopicIDs`，也不创建用户学习主题。生成描述的同一次视觉模型请求同时返回根级 `tags`：主分类在第一项，最多两个明确次分类，不凑数。服务端、数据库和客户端都校验稳定 ID、去重并保留顺序，最多三项。截图文档按信息载体分类，忽略偶然背景，不根据句子、人物关系、情绪或旅行意图推断照片分类。

独立目录见 `MemoryPhotoCategories.swift` 和 `generate-memory-v2/photo-categories.ts`，共 17 类：人物与合影、美食与饮品、餐厅与咖啡馆、宠物与动物、花草与植物、自然风景、城市与建筑、居家生活、工作与办公、学校与学习、运动与户外、聚会与庆祝、文化与娱乐、交通与出行、穿搭与服饰、物品特写、截图与文档。分类名有中英文翻译。这是产品的照片分类目录，不是 Apple 官方分类或句子学习分类。

复用 `memories.tags` / `guest_generation_jobs.tags` 存储照片分类 ID，保持现有 RPC 参数、返回结构、本地持久化、匿名恢复和登录迁移路径。分类和生成结果、扣次、后台向量任务入队仍在同一事务中；句子的学习分类、表达用途和向量生成不变。缺失或无效照片分类不影响句子生成成功，归入“未分类”；不通过句子分类补猜，也不自动重新分析旧照片。同一照片在同一分类只计数一次，可以同时属于多个分类，只显示包含照片的分类。

分类详情沿用日期排序、渐进显示、图片按需下载、照片详情和删除确认，底部提供“翻一翻”。队列从该分类的全部照片生成，不受列表已显示页数限制，使用这些照片关联的全部句子，不混入其他照片。翻看记录、朗读预取和共享音频缓存不变。回忆导航使用 `MemoryNavigationRoute` 区分照片详情和主题相册，外部照片链接仍进入照片详情。主题详情下底部主 tab 栏隐藏，返回后保留根页已选的浏览方式。

部署顺序：先运行数据库迁移 `20261009000000_add_photo_scene_categories.sql`，再部署 `generate-memory-v2`，最后更新客户端。新迁移只替换两个 finalize RPC 中的旧照片标签白名单，不增加列，不修改旧照片、不改变函数签名。`recover-guest-generation` 已透传 tags，无需重新部署；其余函数、环境变量和 Nginx 配置无需调整。未部署迁移就部署函数会导致数据库过滤掉新照片分类 ID。

2026-10-09 本地验证：全部 Edge Function 类型检查通过；生成、分类、恢复及数据库事务相关 74 项测试（29 子步骤）通过；隔离 iOS 模拟器构建和 274 项测试通过，另有英文分类相册 14 项测试通过，并核对中英文深浅色界面。覆盖三个模型的分类透传、重复请求只扣一次、失败回滚、匿名恢复、登录迁移 payload、云端读取、本地序列化和按分类翻看边界。未调用真实 AI 或 staging/production API，线上分类准确性仍需部署后用照片验证。

## 生成完成后的单轮翻看

“新的”生成结果底部提供主要按钮“翻一翻”，只传入当前回忆的句子，以 `AlbumFlipMode.singlePass` 随机无放回翻看，两组共六句全部展示一次后结束。左滑和右滑沿用独立的翻看熟悉度记录、持久化和登录用户云端同步，不改变填空学习掌握度；本轮即使左滑也不重复插入句子。语音自动播放、接下来最多五句预取及共享缓存复用既有实现，结束时停止朗读及预取。

翻看当前卡片的图片首次加载时轻微淡入（约 180 毫秒）；图片尚未加载时保留既有占位。后方卡片预加载好的图片保持可见，滑动过程中已经露出的图片不会在切成当前卡片时重新设为透明，避免“先出现再闪一下”。动画仅作用于首次显示的图片，不改变句子文字、卡片尺寸和滑出动画。开启系统“减少动态效果”时直接显示图片，不执行淡入；重试加载、退出取消及图片下载链路不变。

生成结果底部提示“内容已生成，试试翻一翻吧”。结束页的圆角虚线框与前面的翻卡区域共用尺寸和位置，底部原操作区隐藏但保留布局占位。框内铺满浅灰色斜线背景，中央用灰色文字提示“这张已经翻完了，再来一张吧”，下方是独立的“再上传一张”按钮，点击框的其他区域不会触发选图。点击按钮后先关闭全屏翻看窗口，在 `fullScreenCover.onDismiss` 后开启系统选图；取消选图保留旧结果，选择成功后走原读取照片流程，不自动发起新的生成或扣次。网络不可用时禁用继续选图并提示连接网络，中英文文案均已接入。回忆页保持默认 `continuous` 模式，仍可以无限翻看。此功能只改客户端，无需数据库迁移、函数部署或环境变量变更。

## 24. 当前高价值待办

这些不是必须立刻做，但长期有价值：

- 发布前：执行 `Backend Database` workflow，先对 `staging` 再对 `production` 应用 `20260728000000_allow_direct_sentence_study.sql`。该 migration 允许“去学习”保存未收藏句子的学习记录，同时不改变收藏学习队列只读取收藏内容的规则。
- 继续把用户可见中文文案迁移到 `L10n`。
- 给生成恢复、扣次数、匿名登录迁移增加更多自动化兼容测试。
- 继续拆分 `AppModel`，但要小步做，避免影响业务链路。
- 优化 `ProfileView` 等大型 SwiftUI 文件的组件拆分。
- 给 `persistMemories` 进一步做 debounce 和后台 I/O 优化。
- 定期审计 Edge Function 与线上环境是否一致。
