# 句子元数据退役（2026-10-16）

## 当前生成与同步契约

- 英文接口每项仅由模型生成 english、chinese；服务端补充句子 ID、分组和收藏状态。
- 多语言接口保留 targetText、translationText、presentationGroup，以及非英语填空必需的 learningMaterial。日语读音和分词不属于本次删除范围。
- 照片 tags 继续由模型根据图片本身生成，用于回忆的“按主题”；不再分类每一句话。
- 不再请求、解析、上传或保存句子分类、表达用途及原句/用途向量；提供方返回的多余字段会被过滤。
- 生成后不再派发后台补全或匹配任务，客户端不再轮询后台补全耗时。前台 GenerationTiming 日志保留。
- 句子文本、翻译、照片、ID、收藏、填空材料、学习记录和既有翻阅历史均保留。旧本地分类可被解码，但再次保存/上传时不再写入。

## 数据迁移

新增 `20261016000000_remove_sentence_metadata.sql`，不修改历史迁移。

迁移更新 v2/v3 生成落库、内容 DTO、校验和匿名导入；保留事务扣次、幂等恢复、所有权检查和请求上下文校验。旧匿名恢复 JSON 删除分类/用途字段，其余内容和身份不变，维护更新完成后恢复不可变结果触发器。

原退役迁移删除了 `memory_sentences.learning_topic_ids`。2026-10-20 发现已发布旧版仍在回忆列表的显式 select 中请求此字段，导致 PostgreSQL `42703`、HTTP 400，回忆与收藏一起无法加载。后续迁移 `20261020000000_restore_legacy_sentence_topic_column.sql` 补回同名 `text[]` 字段，默认空数组，作为旧版兼容占位；不恢复分类计算、已删除的分类数据或向量任务。

其余退役范围保持：删除句子向量、匿名向量、多语言向量、主题向量及补全任务/耗时表；移除已退役的主题匹配和向量触发器/RPC。不删除句子学习历史或旧主题与句子的关联记录。没有使用 CASCADE，未知外部依赖会让整个迁移回滚而不是连带删除。

分类/用途/向量属于本次有意删除的派生数据，迁移后不会自动恢复。正常数据库备份仍应在发布前完成。

### 2026-10-20 旧版兼容修复已上线

经用户授权，修复提交 `c9cb81b` 的兼容迁移已先在 staging、验证后再在 production 执行。staging 状态检查确认仅此一条迁移待执行，两次 apply 日志也都仅应用 `20261020000000_restore_legacy_sentence_topic_column.sql`。

- [staging 发布 #235](https://github.com/lvyoungyoung/Sanju/actions/runs/39364427001)：检查与迁移均成功。
- [production 发布 #236](https://github.com/lvyoungyoung/Sanju/actions/runs/39365015845)：检查与迁移均成功。
- 两个环境均用公开密钥、新建临时普通会话，分别通过原 API 中转和 Supabase 直连执行已发布旧客户端的完整回忆 select（含 `learning_topic_ids`）及收藏关联查询，均返回 HTTP 200。先前的 HTTP 400 / PostgreSQL `42703` 已消失。
- 新版 `list_memories_v2` 对匿名测试会话仍返回预期的 `403 / Sign in required`。线上查询验证使用的是空临时账号，没有读取真实用户内容；临时账号均已通过现有删除账号函数清理。
- 本地 PostgreSQL/PGlite 测试覆盖有历史句子/收藏时的字段恢复、新行默认空数组、重复应用、普通用户收藏修改、账号隔离，以及不恢复分类/向量任务；另有退役回归 5 个步骤通过。发布前 CI 同样通过新增兼容回归。

此修复无需更新旧客户端、重新部署 Edge Functions、修改 Nginx 或调整白名单。旧版点击重新加载即可重试。线上写入测试造数曾遇到既有 `valid_generation_spec_v3` 执行权限问题，本次未扩展数据库权限；线上验证范围为旧版读取恢复，带数据的收藏写入与隔离由本地数据库回归覆盖。

## 部署

仅推送代码不等于已部署。发布窗口内先停止新的生成测试，完成数据库迁移，再部署函数并更新客户端，然后恢复测试；不要长时间保留新旧契约混用。

建议 GitHub 的函数部署选择 `all`。本次必须更新：
- `generate-memory-v2`、`generate-memory-v3`
- `recover-guest-generation`、`import-guest-memories-v1`
- `process-generation-enrichment`、`create-study-scene`、`review-study-scene`、`extract-study-topic-expressions`（退役响应，避免线上旧端点继续工作）

`recover-generation-v2` 的实现不变，读取更新后的数据库恢复契约。无需新增密钥、代理设置、定时任务或第三方模型配置。

## 验证

本次本地结果：后端回归 171 项通过；新增退役数据库测试包含 5 个步骤；客户端 37 项通过，编译无警告。函数入口检查全部通过。没有把其他未提交的界面或翻阅改动纳入本次提交。

- 本地 Deno 回归覆盖提供方回退、异常恢复、重复请求扣次、提示词格式、照片分类、内容权限及多语言链路。
- 新增本地 PostgreSQL/PGlite 退役迁移测试：有历史匿名结果、向量数据和触发器时迁移；新/旧匿名恢复与迁移；六句生成；幂等扣次；收藏与学习记录；权限隔离。
- 客户端隔离副本编译及协议/同步/恢复测试；模拟器服务地址改为 localhost 的不可用端口，不访问 staging/production。
- 未进行线上迁移、真实 AI 请求或部署。旧分类/用途基准脚本及相关运行时代码已退役，历史数据库回归仍保留用于验证旧迁移。
