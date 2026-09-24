# 图片生成完整链路

核对日期：2026-09-21。依据当前本地仓库代码及迁移顺序整理，已更新任务执行权和完整响应超时改动，未连接 staging / production 验证实际部署版本、环境变量、Nginx 配置或运行日志。

## 1. 总览

当前客户端发送 `generationFormat: dual_tabs_v1`，一次生成两组、每组三句，共六句。未传该参数的旧客户端走 `legacy_v1`，生成三句。两种格式成功时均扣一次生成次数，不按句数扣。

```text
选择照片 → 系统读取照片 → 本地预览
点击生成 → 网络/余额/本地频控 → 压缩图片 → 确认身份
→ 持久保存本次请求标识和待恢复图片
→ POST generate-memory-v2
→ 服务端鉴权/查询资料/检查已有任务/余额/封禁/并发名额
→ 创建 pending 任务（匿名先存恢复用图片）
→ 阿里云图片审核（启用时）
→ MiMo → 失败时 Kimi → 解析和规范化
→ 登录：上传图片 → 事务保存回忆、句子、扣次、完成任务
→ 匿名：事务保存可恢复任务结果、扣次、完成任务
→ 写诊断信息 → 句子向量化/匹配已有主题
→ 返回 JSON → 手机保存回忆、余额并展示
→ 登录用户另行用较清晰的回忆图覆盖云端分析图
```

## 2. 选图与预览

入口为 `三句/NewLearningView.swift`。无网络时禁止打开选图；有网络时使用系统 `PhotosPicker`，选择后立刻进入“正在读取照片”。

通过 `PhotosPickerItem.loadTransferable(type: Data.self)` 取得图片数据，读成功后更新本地草稿并显示预览。这个阶段没有调用生成接口、内容审核或向量服务，也没有把照片上传到业务后端。系统照片读取仍可能依赖 iCloud；是否请求云端由系统照片机制决定，不能仅凭“这是新拍的照片”断言所有系统操作都不涉及网络。

照片读取使用 20 秒计时任务与读取任务竞速，并用请求 UUID 防止较早的选择覆盖较新的选择。Swift 任务组退出仍需等待子任务完成，因此计时取消依赖底层读取对取消的配合，不应视为无条件的硬截止。

## 3. 点击生成后的客户端准备

`NewLearningView.generateSentences()` 检查有图、网络可用、没有被恢复交互锁住；然后开启生成状态。`AppModel.generateMemory(from:)` 再检查余额并消耗本地“尝试频次”额度。

本地生成频控为滚动 60 秒最多 10 次、滚动一小时最多 100 次尝试。它不是用户购买的生成余额：尝试后失败仍可能计入频控，但真正的扣次发生在服务端提交事务时。

`ImageCompressor` 生成两份 JPEG：

| 用途 | 目标大小 | 尺寸与质量尝试 |
| --- | --- | --- |
| 模型分析图 | 45,000 字节以内 | 最长边依次 512/416/352；JPEG 质量 0.07/0.045/0.03 |
| 本地回忆及后续云端覆盖图 | 160,000 字节以内 | 最长边依次 1280/1120/960；JPEG 质量 0.34/0.28/0.22 |

图片按比例缩小，不放大；超过目标大小会进一步压缩。兜底分别使用 352/0.022、960/0.2，兜底结果没有再强制校验字节上限。因此上面的大小是目标，不是绝对保证。原始选图数据保留在当前草稿，不直接作为本次生成请求的图片。

随后 `ensureValidSession()` 确保有效身份。未登录产品账号也不是完全无身份请求，而是 Supabase anonymous user，有自己的用户 ID、令牌和服务端余额。

客户端为本次操作生成 `clientRequestID`；匿名用户另有 `guestJobID`。发请求前，将开始时间、此前回忆 ID 集合、请求标识及回忆版图片保存为 `pendingGeneratedMemoryImage`，供请求中断后恢复。同一次 JWT 刷新重试会复用原标识。

## 4. 请求与网络路径

`SupabaseService.generateMemorySentences()` 发送普通 JSON POST 到 `/functions/v1/generate-memory-v2`，不是客户端直连模型，也不是流式输出。

请求体包含分析 JPEG 的 Base64、难度 raw value、风格 raw value、`guestJobID`（匿名时）、`clientRequestID` 和 `generationFormat`。请求头包含项目 `apikey` 和用户 Bearer token，不包含 MiMo/Kimi/百炼的秘密密钥。

当前配置中的入口为 staging `https://api-staging.sanju.cc`、production `https://api.sanju.cc`。按项目代理设计，流量经 ECS/Nginx 转发到 Supabase 网关及 Edge Runtime；本次未检查线上 Nginx 的实际 upstream 或超时设置。

生成请求使用 `URLSession.shared` 和普通 `URLRequest`，没有设置生成专属的 `timeoutInterval`，也没有启用该 POST 的普通超时重发（`retryOnTimeout` 默认 0）。不能把登录请求的专属超时或上传图片的 30 秒超时套到生成请求上。

## 5. 服务端前置检查

`generate-memory-v2` 按以下次序执行：

1. 检查 POST、必要环境变量、Authorization；用 `auth.getUser(token)` 核验身份。
2. 读取该用户的 `profiles.available_generations` 和封禁时间；解析 Base64、难度、风格和格式。
3. 检查是否已有完成任务。完成的相同请求优先复用结果，不再次走生成和扣次；匿名 pending 返回处理中、failed 返回失败。
4. 检查服务端余额。启用违规封禁时，再检查封禁是否有效。
5. 调用数据库 `try_acquire_generation_slot` 获取本项目共享并发名额，函数传入上限 50，租约 180 秒。没有名额直接返回 429，不排队。
6. 通过服务端专用 RPC `claim_generation_job` 原子插入 pending 任务，只有返回 acquired 的请求能继续执行；已存在的 pending/completed/acknowledged/failed 任务分别返回处理中、原结果或失败，不覆盖任务、不重新生成。跨账号复用请求 ID 被拒绝。无请求 ID 的旧登录客户端保持原流程。

内部 Supabase 调用优先用系统提供的 `SUPABASE_LOCAL_URL`，缺失才退回 `SUPABASE_URL`，避免绕公网回源。模型地址和密钥来自各自环境变量。

并发名额覆盖审核、模型生成、保存、向量处理等已获名额后的处理阶段，不只是模型请求。正常结束或异常进入 `finally` 时尝试释放；运行时被终止等情况依靠租约失效后的清理兜底。鉴权和前置查询发生在取名额之前，所以“50”不是全部 HTTP 请求数量上限。

## 6. 图片审核

审核在模型生成之前，发生在服务端。匿名用户先把分析图存到 `memories` Storage 的 `<userID>/guest/<guestJobID>.jpg`，用于恢复；登录用户此时还没有保存正式回忆图。

启用 `IMAGE_MODERATION_ENABLED` 时，生成函数调用 `moderate-image-v1`。该函数使用阿里云 `DescribeUploadToken` 取得临时上传凭证，把分析图片上传到审核用 OSS，再调用阿里云审核接口。虽然生成函数传了 `existingImagePath`，当前审核函数实际只消费 Base64，不读取该 Storage 路径。

只有阿里云返回的高风险或代码列出的严重标签导致 `policyViolation: true`，才作为图片违规阻断。MiMo/Kimi 响应里的文字不用于认定图片违规。

审核通过则继续；审核未启用、配置缺失、请求错误、响应异常或超时均按当前宽松策略放行并尽量记录日志。明确违规则不调用模型、不扣次，任务标为失败，匿名临时图片尝试删除，返回 HTTP 403 和 `generation_policy_violation`。客户端把该错误作为不可恢复错误，直接结束生成等待。

违规封禁另受 `GENERATION_VIOLATION_BAN_ENABLED` 控制：代码参数为 24 小时窗口、20 次违规阈值、封禁 24 小时。本次未读取线上开关值。

## 7. 模型生成与解析

首先调用 `mimo-v2.5`，关闭 thinking，`max_completion_tokens: 4096`。把同一分析图作为 `data:image/jpeg;base64,...` 与文本提示一起发送。

新格式在一次模型调用里生成两组，不是分别调用两次：

- `image_descriptions`：三句客观画面描述，不推测人物关系或感受。
- `scene_and_feelings`：三句场景表达，依次表达当时的感受、当时会对别人说什么、发生了什么。第二句是贴合照片场景的单句假设性口语（如邀请、提问或请求），不是双方对话，也不声称对话真实发生过；允许有画面依据的场景推测，但不编造具体姓名、地点等细节。
- 三句场景表达不提供固定英文范句，避免套用模板；第二句也可以分享发现或提出建议，不默认请求拍照，只有画面本身明确涉及拍照活动时才考虑这种表达。
- 每句包含 `english`、`chinese`、`learning_topic_ids`；另返回照片级 `tags`。

难度和风格来自用户设置；生活表达要求自然日常，不因高级或抒情设置变成书面文学。启蒙对两组均优先要求 3–6 词的超短句，并忽略抒情风格。长度、语气和事实约束主要是提示词要求，不是逐句执行的硬规则校验。

句子分类来自 21 个生活场景，最多两个、主场景在前，没有合适分类允许空数组；照片 tags 是另一套 11 项的集合，最多三个。分类不是新建主题操作，不会因此自动创建用户学习主题。

MiMo 的网络失败、超时、HTTP 错误、429、空内容或句子结构解析失败，当前都会成为切换 Kimi 的原因。Kimi 使用 `kimi-k2.5`，同图同提示重新生成，不是让 Kimi 修复 MiMo 的半成品；两者串行、各请求一次，不循环重试。

双组解析要求两组各得到三条非空中英句子，否则失败。解析会清理 JSON 外壳并规范化分类，未知分类被过滤；旧三句解析还有正则和缺失字段的宽松兜底，双组不能假定拥有同样的兜底能力。

MiMo 成功则 `provider=mimo`、`mimo_failure_reason=null`；MiMo 失败而 Kimi 成功则 `provider=kimi`，另存 MiMo 失败摘要。两者失败时写组合日志、标记任务失败并返回错误，没有进入扣次事务。

## 8. 保存与扣次：登录用户

模型结果通过解析后，服务端给各句分配稳定 UUID，设 `is_favorite=false`，标记 `what_i_see` 或 `what_i_say`。

生成函数先将分析图上传到 `memories` Storage 的正式路径。上传失败直接返回，不扣次。上传成功才调用 `finalize_authenticated_generation`。

finalize 定义来自 `20260901000000_replace_scene_hint_with_learning_topics.sql`，并由 `20260921005000_claim_generation_jobs_atomically.sql` 的触发器保护终态，在同一数据库事务中：

1. 检查句数为 3 或 6；锁定同用户同请求的任务，已完成则复用结果。
2. 锁定 profile 并重新检查余额，处理已有 memory 的幂等情况。
3. 插入 `memories`，保存图片路径、时间、provider、tags。
4. 插入 `memory_sentences`，保存句子、分类、分组、顺序和收藏状态；关联触发器可同步匹配已有的分类主题。
5. 余额减一；如果流水表存在，写入 `generation_transactions`。
6. 将 `generation_jobs` 标为 completed，写 memory ID、图片路径和扣次后余额。

收到明确 SQL 失败时，事务整体回滚，生成函数尽力删除已上传图片并记录任务失败。若只是 finalization 请求网络中断或响应超时，不能断言回滚：保留任务和图片，返回可恢复的超时响应，不盲目删图或标记失败。Storage 上传不是数据库事务的一部分，所以仍可能存在补偿删除失败留下的孤立图片。

旧客户端没有 `clientRequestID` 的请求仍可生成、保存和扣次，但无法对不同 HTTP 请求提供请求 ID 级别去重。新登录客户端与匿名请求都有原子执行权保护。保存后的返回值从数据库实际任务/回忆读取，诊断补写不再修改完成状态、memory ID 或余额。失败更新只针对当前执行者所属账号的 pending 任务；触发器禁止终态回退和覆盖已完成结果，允许匿名 completed -> acknowledged 及删除回忆导致的 memory 外键清空。

任务不自动超时抢占执行权，避免尚未停止的旧执行者与新执行者同时运行。执行权取得后进程被杀死、或 claim 响应丢失，可能留下 pending；旧请求只查询，不重新生成，用户发起新的生成会使用新请求 ID。这轮没有引入持久后台队列或自动接管机制。

## 9. 保存与扣次：匿名用户

匿名调用 `finalize_guest_generation`。该事务锁定匿名任务和 profile，检查余额，扣一次，将完整句子、稳定句子 UUID、tags、provider、剩余次数写入 `guest_generation_jobs` 并标记 completed，同时在存在流水表时写生成流水。重复完成同一 job 不会再次扣次。

重要区别：此处不插入正式 `memories` 和 `memory_sentences`。匿名的原子性是“云端可恢复结果和扣次一起提交”，不是“手机本地回忆和扣次一起提交”。客户端收到结果或恢复结果后才建立本地回忆，设置 `syncedToAccount=false`，保留句子 UUID，并加入后续登录迁移队列。

所以客户端没有收到响应时，服务端可能已经扣次，但匿名任务中已经保存了可恢复结果；恢复失败、本地状态丢失或恢复期限过去，仍可能导致手机没有显示结果，不能用数据库事务保证跨手机、HTTP、Storage 的全过程原子性。

## 10. 返回前还有哪些工作

提交事务后，生成函数会更新 provider/MiMo 失败原因诊断，然后等待句子向量处理完成或报错：

- 百炼 `qwen3.7-text-embedding`，输入为每句的英文和中文，批量生成 1024 维 dense 向量，不传照片、不再用 `scene_hint`。
- 登录用户写 `sentence_embeddings`，再刷新每句与已有自定义语义主题的关系。当前阈值默认/最低 0.42，AI 逐句复核已暂停；预定义主题按分类匹配。
- 匿名用户写 `guest_sentence_embeddings`，以后登录迁移时凭稳定句子 UUID 提升为正式向量，不在此处创建匿名自定义主题。

这些工作是 best-effort：失败捕获后记日志，不撤回生成、不返还次数。但是当前使用 `await`，仍在 HTTP 返回前执行，并非完全放到后台，因此向量或主题查询慢会拉长用户等待。向量失败也意味着相关句子可能暂时不能进入语义主题，不能视为索引必然成功。

最后返回 JSON：`memory`（ID、图片路径、创建时间、provider、tags、句子）及 `remainingCredits`，另含相应请求/job ID。旧格式会裁剪到三句，双组格式保留分组信息。

## 11. 客户端落地与图片覆盖

客户端解码并检查句子数量及非空中英内容，用较清晰的回忆版 JPEG 建立 `MemoryEntry`，更新本地回忆列表、草稿、次数和持久化，清除待恢复标记。不会自动收藏句子。

登录用户接着将回忆版 JPEG 上传到相同的云端图片路径，覆盖服务端先保存的分析图。上传前加入待上传队列，失败保留队列，不把已经生成成功的结果改成失败。正常生成函数会等待这次上传尝试返回，但本地草稿和回忆此前已经写入，UI 可以先观察到结果。

匿名正常返回使用本地回忆图，不上传正式账号回忆图片；服务端匿名分析图仍用于临时任务链路。恢复期间本地待恢复图片仍存在时，可以使用它，不必依赖分析图来显示本地回忆。

因此云端可能短暂存在较模糊分析图：上传覆盖未完成、失败等待重试或客户端中断时均可能出现。图片覆盖不参与扣次，也不再次调用模型。

## 12. 失败、锁屏和恢复

明确违规、封禁、无次数、限流等不可恢复错误直接结束。超时、连接中断、部分可识别网关错误及无网络等才进入恢复判断；未知错误并非一律恢复。当前部分判断依赖错误文本，而非统一的 HTTP 状态枚举。

遇到明确 `Invalid JWT` 时尝试刷新 session 并用原请求 ID 重发一次。它不同于“超时重发生成”。普通生成异常优先查询旧任务，不重新调模型。

| 情况 | 恢复方式 |
| --- | --- |
| 登录用户 | 按用户 ID + `clientRequestID` 查询 `generation_jobs`；completed 后同步回忆元数据并按 memory ID 找结果；failed 时停止 |
| 匿名用户 | 调 `recover-guest-generation`，按同一匿名用户 + `guestJobID` 读已完成任务；不调模型、不重复扣次；保留句子 UUID |
| 较旧无请求 ID 的待恢复记录 | 同步回忆，通过新增 memory ID 和内容完整性尝试识别结果 |

匿名恢复函数读取 completed/acknowledged 任务；首次读取 completed 会将其设为 acknowledged，但这是服务器已提供结果的标记，不证明手机已成功写盘。acknowledged 仍可再次读取，直到任务清理。

首次登录请求出错后的快速恢复间隔为 0.8/2/3/4 秒；显式恢复及匿名恢复的间隔为 0/5/10/20 秒。这些是每次尝试前的等待，不是整轮时限，每次网络调用还要加实际耗时。客户端每个恢复子操作以 12 秒做竞速控制，取消同样依赖底层操作配合。

进入生成页、应用回到前台、网络恢复时，页面会尝试恢复保留的任务；无网时停止显示假进度，提示连接网络后获取结果。完整的显式恢复一轮仍无结果时清除待恢复状态，不在每次打开 App 时无限重试。取消任务或 session 暂时无法准备好可能提前退出，不等同于已跑完一轮。

本地待恢复记录超过开始时间 24 小时失效。服务端 `cleanup-guest-generation-jobs` 被执行时，会清理创建超过 24 小时的匿名任务和对应临时图片，无论是否 acknowledged；本次未检查线上调度频率。匿名恢复不是永久备份，清理代码没有自动退次数逻辑。

锁屏或切后台后，请求的两端不一定同步终止：手机可能暂停或丢失响应，而服务端继续完成事务。因此“请求失败”不能直接推导“未生成”，需要任务状态判断；反过来“恢复没找到”也不能证明服务端永远不会完成。

## 13. 时间预算和 UI 提示

| 阶段 | 代码设置 | 注意事项 |
| --- | --- | --- |
| 读取照片 | 20 秒 | 本地任务竞速，可能包含系统 iCloud 读取 |
| 生成函数等待审核函数 | 10 秒 | 失败/超时放行；审核内部还包含获取凭证、OSS 上传、实际审核 |
| 审核内部 | 凭证/审核请求各 10 秒，OSS 上传 15 秒 | 不应简单累加成主生成函数必等的时间 |
| MiMo | 20 秒 | 失败后才尝试 Kimi |
| Kimi | 20 秒 | 不与 MiMo 同时跑 |
| 句子 embedding | 8 秒 | 提交成功后仍在返回前等待 |
| 客户端回忆图片上传 | 30 秒 | 发生在本地保存之后，失败转待上传队列 |
| 恢复子操作 | 12 秒 | 还要加多轮等待，且取消并非无条件硬截止 |

模型、审核外层、审核内部 OSS/RPC、embedding 现在共用完整响应读取的超时工具：连接、响应头和响应正文都在计时内，超时会中止请求并结束等待。原来的分阶段时长不变。

一次 `generate-memory-v2` 处理还共享 90 秒的网络预算，鉴权、数据库、Storage 和模型等出站请求都会受到剩余预算限制；接近预算时，不再给下一阶段重新分配完整时长。失败标记和释放并发名额使用独立的 5 秒清理请求，通常最多两次。90 秒不是照片读取、客户端恢复、多次重试或 Edge Runtime CPU 工作的统一硬上限，也不能阻止已经提交到数据库的事务随后完成。客户端生成 POST 仍保持原来的超时设置。

页面“正在识别图片内容”等步骤每 2 秒由客户端定时切换，不来自后端实时进度。不能根据当前文案判断服务器正在审核、等模型还是保存结果。响应一次性返回，没有 SSE/token 流。

## 14. 排查时区分三个成功点

1. 模型成功：文本已生成并通过解析，还未必保存或扣次。
2. 云端业务成功：登录回忆或匿名可恢复结果与扣次一起提交；后续向量失败不会撤回。
3. 客户端可见成功：手机收到或恢复结果并写入本地，图片覆盖还可能在重试。

这三个时刻不是同一时刻。判断“扣了次数却没看到内容”时，先看相应 job 和事务结果，再看客户端恢复状态，不能只看模型后台或页面提示。

## 15. 主要代码入口

- `三句/NewLearningView.swift`：选图、生成按钮、进度展示、恢复交互。
- `三句/AppModel+Memories.swift`：图片准备、请求标识、生成请求、结果持久化、恢复、图片补传。
- `三句/ImageCompressor.swift`：分析图和回忆图压缩参数。
- `三句/SupabaseService.swift`、`三句/SupabaseModels.swift`：请求/解码/错误分类。
- `supabase/functions/generate-memory-v2/index.ts`：前置检查、审核、模型切换、提交、向量和响应。
- `supabase/functions/moderate-image-v1/index.ts`：阿里云 OSS 上传和审核风险判断。
- `supabase/functions/recover-guest-generation/index.ts`：匿名已完成结果读取。
- `supabase/functions/cleanup-guest-generation-jobs/index.ts`：匿名结果保留期清理。
- `supabase/migrations/20260901000000_replace_scene_hint_with_learning_topics.sql`：当前带分类/分组的两种 finalize 事务。
- `supabase/migrations/20260921002000_pause_study_scene_ai_review.sql`：当前生成后自定义主题语义匹配、不再逐句复核。
- `supabase/migrations/20260921005000_claim_generation_jobs_atomically.sql`：原子执行权、账号隔离和终态保护。
- `supabase/functions/_shared/fetch-with-timeout.ts`：完整响应读取超时、父请求取消与共享网络预算。

## 16. 本轮部署与验证

先对 staging 应用 `20260921005000_claim_generation_jobs_atomically.sql`，再部署 `generate-memory-v2` 和 `moderate-image-v1`（会打包共享模块，不单独部署 `_shared`）。客户端增加 `generation_in_progress` 恢复分类，需重新构建；旧三句接口和 finalize 签名不变。`recover-guest-generation` 本轮未改，不需要重新部署。前置迁移须已按顺序应用。

测试涵盖重叠 HTTP 请求只执行一次模型、已完成结果复用、跨账号 ID、回滚/扣次、响应丢失保留结果与图片、匿名 acknowledged、旧三句请求、正文停滞切换 Kimi、双模型停滞不扣次、父取消和完整响应状态保持。数据库测试使用本地 PGlite 执行真实 SQL；HTTP 测试使用真实 handler 与本地替身，不调用付费模型；没有做线上负载测试或真实多连接 PostgreSQL 压测。
