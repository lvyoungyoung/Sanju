# 多语言第一期实现与发布核对

日期：2026-10-14

状态：代码实现及本地集成验证；未部署，未完成第一期上线验收。
范围依据：`multilingual-phase-one.md`、`multilingual-architecture.md`。
本次包含用户明确同意一起提交的已有客户端界面改动，不包含视频产物、密钥或无关研究文件。

## 实现内容

- 单一语言目录生成 Swift 与 TypeScript 定义，覆盖 4 种学习语言、5 种翻译/讲解语言和 10 个合法组合；界面仍只有简体中文与英文。
- 设备界面语言独立保存；学习组合、各语言难度和音色按账号同步。采用字段版本冲突检查，游客偏好不会覆盖已有账号偏好；损坏缓存不会被静默重置。
- 新用户确认学习组合，生成入口显示学习语言和难度；旧用户保留英语历史。回忆可跨语言浏览，收藏、待学数和每轮复习按同一语言过滤。
- 点击生成时固定不可变请求快照。新生成、断线恢复、访客导入、分页同步和删除均保留内容语言、版本与稳定 ID。旧入口只处理其理解的英语数据。
- 英语、西语、日语、法语使用各自的生成及练习规则；日语保存可验证的分词/假名材料，不按英语空格拆词，挖空答案不通过读音泄露。
- 学习激活、每日总额度、会话快照、答题事件与重试回执分离；跨语言不重复扩充每日额度。游客未完成练习及答案草稿可重启恢复，登录后导入其记录。
- 语音请求、预加载和缓存携带语言、教学变体、音色版本及账号上下文；回退只选择相应语言的系统音色。英语保留现有 MiMo 音色。
- AI 解析保持按需生成、打开详情只查缓存；新缓存区分目标语言、讲解语言及内容版本。界面切换同时刷新通知与小组件的界面文案，不改历史句子。
- 删除照片写入持久化清理队列，由现有维护函数消费；失败保留重试记录，删除前检查图片引用与路径归属。

## 本地验证

所有客户端测试使用独立 iOS 27 模拟器，测试产物的后端地址改为不可连接的本机地址；未改源码配置，未调用 staging/production API、购买或实际模型。

| 检查 | 结果与证据 |
| --- | --- |
| 语言目录一致性 | `node scripts/generate-language-catalog.mjs --check` 通过 |
| Edge Function 类型检查 | 19 个入口通过；`/tmp/sanju-multilingual-edge-check.log` |
| 新增后端测试 | 41 项测试、43 个子步骤通过；`/tmp/sanju-multilingual-deno.log` |
| 既有后端回归 | 165 项测试、103 个子步骤通过；`/tmp/sanju-backend-regression.log` |
| 客户端最终编译 | `build-for-testing` 通过；`/tmp/sanju-multilingual-verified-build.log` |
| 客户端最终回归 | 461 项测试全部通过，0 失败，耗时约 156 秒；`/tmp/sanju-multilingual-verified-tests.log`、`/tmp/sanju-multilingual-verified-tests.xcresult` |

数据库测试执行真实迁移，但基线是本地 PGlite 合成结构，不是线上导出。覆盖所有者隔离、旧入口限制、权限、偏好版本冲突、扣次/恢复幂等、内容材料校验、学习额度/事件、缓存与删除队列。不等同于托管数据库实测。

早期完整客户端测试有 447 项通过。最终集成时发现引导英文文案断言过时，以及朗读设置行独立渲染缺少外层状态的问题，已分别更新断言、改为显式传入学习语言，再运行最终回归。另补上游客练习重启恢复的测试。

## 部署清单

推送代码不等于部署授权。先核对 staging 实际结构，再按 `backend-release-process.md` 先数据库、后函数、最后客户端联调。同一验证过的版本才能继续 production。

### 数据库

本次有 4 个新增迁移，必须按顺序执行：

1. `20261013000000_multilingual_content.sql`
2. `20261013002000_multilingual_generation.sql`
3. `20261013003000_multilingual_study.sql`
4. `20261013004000_multilingual_explanations.sql`

不要修改已经执行过的历史迁移，也不要在未核对线上基线时盲目应用。

### Edge Functions

新增 5 个：`generate-memory-v3`、`recover-generation-v2`、`import-guest-memories-v1`、`explain-sentence-v2`、`synthesize-speech-v2`。

更新 4 个：`generate-memory-v2`、`recover-guest-generation`、`explain-sentence`、`cleanup-guest-generation-jobs`。

共享模块随依赖入口打包，不单独部署。`process-generation-enrichment` 的停用入口未改，不需要为本次单独部署。

### 配置与开关

- 无新增代理/Nginx 配置；保留现有 Supabase、DeepSeek、MiMo、Kimi、向量及审核配置。
- `language_capabilities_v1` 初始仅开放现有中文学英语生成；其他 9 个组合的 `can_generate=false`。已有内容读取、恢复及支持的解析不依赖生成开关。
- `SPEECH_V2_VALIDATED_PROFILES` 默认留空。西语、日语、法语的 OpenAI 候选音色尚未做真人听音验收，不能宣称已支持高质量云端朗读。
- 后续验证候选音色时配置 `OPENAI_TTS_URL`（完整语音接口地址）、`OPENAI_TTS_API_KEY`；验收通过后才将相应 `es-coral-candidate@1`、`ja-coral-candidate@1`、`fr-coral-candidate@1` 加入上面的白名单。密钥只放服务端。
- 核对已有维护任务是否用 service-role 鉴权定期 POST `cleanup-guest-generation-jobs`。本次只实现其消费能力，没有创建或修改线上调度。

## 尚未完成的上线验收

- staging 实际表、RLS、Storage 策略、触发器和 SECURITY DEFINER 函数只读清单。当前没有可用的 staging 连接，未使用指向 production 的连接替代。核对步骤见 `multilingual-database-fixtures.md`。
- 托管 PostgreSQL 多会话并发、真实照片存储清理、旧客户端共存、登录迁移与跨设备联调。
- 全部 10 个组合与 3 档难度的真实照片生成、自然度、翻译、日语分词/假名及语音人工校对。
- 真机大字体/VoiceOver、海外网络、邮件登录及购买恢复；中英文商店物料与支持/隐私说明核对。

以上未完成项意味着本次可交付代码与本地验证结果，但不能将全部 10 个组合标为已上线或正式可用。
