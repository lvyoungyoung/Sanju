# 两步生成：内容先返回，学习元数据后台补全

## 请求链路

`generate-memory-v2` 仍等待审核、MiMo/Kimi 返回、图片保存和 finalize 数据库事务。
finalize 在同一事务保存结果、扣一次额度，并写入 `generation_enrichment_jobs`。
接口随后返回原来的 JSON，不再等待句子分类、表达用途、向量服务和主题匹配。

第一步恢复到提示词精简之前（`5351ee5`）的完整难度、风格、场景表达和 JSON 示例，
仅移出句子的分类与表达用途要求；随后调整了三个在用难度的梯度，见下节。新客户端两组三句、
旧客户端三句及其顺序不变。照片级 `tags` 仍在第一步产生，与句子分类不同。
初次返回的句子继续包含 `learning_topic_ids: []`，不要求客户端更新。

第二步读取已保存的句子，用一次 MiMo 纯文本请求批量生成这 3/6 句的
`learning_topic_ids` 和 `expression_purpose`。依据句子本身分类，不再上传照片，
不改写英文、翻译或句子 ID。完整的 21 类边界、最多两个有序分类和用途限制保留。
分类/用途通过租约校验后保存到任务的 `metadata`，然后并行生成原句/用途两组向量，
最后落库并匹配学习主题。向量重试复用已保存的元数据，不再次调用分类模型。

后台使用 `EdgeRuntime.waitUntil`，独立的数据库客户端和 45 秒预算，不沿用生成请求的
90 秒截止时间，也不依赖手机继续连接。运行时不支持后台保活时不退回同步等待，任务保留在数据库中；
当前暂不启用定时补偿，因此这种情况下不会自动在空闲期完成，需要排查后台运行能力或人工处理。
参考：[Supabase background tasks](https://supabase.com/docs/guides/functions/background-tasks)。

## 难度分层

画面描述和场景表达统一遵守所选难度，不再对初级和中级的场景表达统一使用 8-18 词：

| 难度 | 目标英文句长 | 词汇与表达 |
| --- | --- | --- |
| 启蒙 | 3-6 词，优先 3-5 词 | 极常见具体词和简单感受词；一个意思，不叠加背景、细节或从句。 |
| 初级 | 6-10 词 | 高频日常词；一个简单分句加一个具体细节，可用简单现在/过去/进行时、疑问句和祈使句。 |
| 中级 | 10-16 词 | 更准确的日常搭配；补充一两个细节或一种关系，允许一个简单从句或并列结构，不嵌套从句。 |

句长是生成指导，不是客户端或解析器的硬性拒绝条件；相邻范围边界允许重合，主要靠词汇、信息量和句式区分。
所选难度高于幽默、抒情和表达层次要求；不能凑字数、删必要成分或为了口语感忽略难度。
启蒙继续强制平铺直叙。旧客户端的“高级”请求仍保留原有描述 14-24 词、场景表达 8-18 词的规则。
这些范围是产品提示词策略，不是标准化语言能力认证；实际输出需要用同一组照片、相同风格对照测试。

本次难度调整只需更新 `generate-memory-v2`，不新增迁移、环境变量或代理配置，
也不需要更新 `process-generation-enrichment` 或 `recover-guest-generation`。

## 完整性与重试

- 成功生成和扣次的事务边界、请求幂等、旧客户端三句返回格式不变。入队失败时整个事务回滚。
- 匿名结果和后台任务都使用稳定句子 ID。后台先完成或登录迁移先完成，分类、用途及向量均由 promotion 触发器接入登录账号。
- 任务领取有两分钟租约；进程被终止后可以重新领取。过期 worker 不能覆盖新 worker 的结果。
- 分类、用途或两路向量任一步失败都不会标记完成。重试不再生成句子、不再扣次数。
- 分类和向量落库、匿名恢复结果补分类、主题匹配、完成任务在另一事务中一起提交；主题匹配失败时全部回滚并保留元数据检查点。
- 服务器在向量表保留权威分类，防止客户端把初次收到的空分类再次上传后覆盖后台结果。
- 没有向量的新句子插入时跳过主题匹配；后台完成后再执行。收藏和学习记录不被后台改写。
- 后台最多同时处理 8 组，每次唤起最多处理 3 组。失败重试间隔从 30 秒倍增到最多 15 分钟。
- 后续生成请求会顺带处理同账号待办；定时补偿暂缓，没有后续生成请求时，失败任务可能持续待处理。
- 完成后清空队列中的句子及元数据副本，保留轻量状态。删除回忆/账号会级联删除相应任务。
- 匿名恢复任务的 24 小时清理不删除未完成的向量任务，与现有匿名向量保留规则一致。
- 不自动补历史缺失向量，不更改主题的匹配阈值、收藏、学习进度和购买逻辑。

生成成功后立即打开主题时，新句子可能还未加入；后台完成后重新获取主题内容即可看到。
这里没有承诺固定缩短几秒。第二步增加一次文本 AI 调用，但减少第一步的提示词任务和输出量；
后台耗时不计入生成结果返回时间，需要用真实照片测试内容质量与前台耗时。

## 部署顺序

1. `Backend Database`：staging + apply，新增 `20260926001000_defer_sentence_metadata.sql`；依赖已部署的 `20260925001000_defer_generation_enrichment.sql`。
2. `Backend Functions`：staging，部署 `generate-memory-v2` 和 `process-generation-enrichment`（二者共用的后台模块已改）。
3. 后台处理复用已有 `MIMO_API_KEY`、`MIMO_BASE_URL`、`DASHSCOPE_API_KEY`、`DASHSCOPE_EMBEDDING_URL`，无新增环境变量。
4. 部署后跑 `node scripts/check-client-compatibility.mjs`，再测试正常/匿名生成、立即登录迁移与主题刷新，确认任务由即时后台处理完成。
5. 完成 staging 验证后按相同顺序发布 production。

按用户要求，已删除每五分钟触发的 `Backend Enrichment Retry` workflow，不再定时调用函数。
不需要配置 `GENERATION_ENRICHMENT_SWEEPER_ENABLED`；如果此前已配置，该变量现在没有作用，可自行删除。
`process-generation-enrichment` 管理入口与主函数一起更新以保持后台逻辑一致；部署不会自行运行，也不启用定时器。
主路径依靠 EdgeRuntime 后台任务处理。不需要调整代理，不需要更新 `recover-guest-generation`，
恢复接口只读取已经保存的结果，不应等待向量。客户端这次没有改动。

迁移后旧生成函数仍能使用相同 finalize 参数；已有任务携带用途时，旧 worker 仍可完成。
新 worker 会为待办补全元数据。新格式任务没有用途时，旧 worker 不能把缺失元数据的任务错误标记完成；
因此迁移完成后要紧接着更新两个函数。无需更新 `recover-guest-generation`，它只读取已保存的结果。
不要只回滚共享 worker 而保留新前台格式。旧 iOS 客户端无需更新。

## 排查

```sql
select status, count(*) from public.generation_enrichment_jobs group by status;

select id, memory_id, guest_job_id, status, attempts, metadata is not null as metadata_ready,
       next_attempt_at, lease_until, last_error
from public.generation_enrichment_jobs
where status <> 'completed'
order by created_at;
```

检查 Edge Function 的 `[generation-enrichment]` 日志，不记录句子全文或向量。
持续失败先核对 MiMo/百炼地址、密钥、实例出公网能力，再检查数据库错误。
`process-generation-enrichment` 仅接受 service-role Authorization，不允许客户端直接调用。
