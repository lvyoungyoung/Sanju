# 生成后的后台向量与主题匹配

## 请求链路

`generate-memory-v2` 仍等待审核、MiMo/Kimi 返回、图片保存和 finalize 数据库事务。
finalize 在同一事务保存结果、扣一次额度，并写入 `generation_enrichment_jobs`。
接口随后返回原来的 JSON，不再等待向量服务和主题匹配。

每句的分类 ID 和表达用途仍随模型生成返回，并非再调用一次模型；移到后台的是
原句/用途两组向量，以及依据这些向量把句子加入学习主题的数据库计算。

后台使用 `EdgeRuntime.waitUntil`，独立的数据库客户端和 45 秒预算，不沿用生成请求的
90 秒截止时间，也不依赖手机继续连接。运行时不支持后台保活时不退回同步等待，任务保留在数据库中；
当前暂不启用定时补偿，因此这种情况下不会自动在空闲期完成，需要排查后台运行能力或人工处理。
参考：[Supabase background tasks](https://supabase.com/docs/guides/functions/background-tasks)。

## 完整性与重试

- 成功生成和扣次的事务边界、请求幂等、旧客户端三句返回格式不变。入队失败时整个事务回滚。
- 匿名结果和向量任务都使用稳定句子 ID。向量先到或登录迁移先到，均由现有 promotion 触发器接入登录账号。
- 任务领取有两分钟租约；进程被终止后可以重新领取。过期 worker 不能覆盖新 worker 的结果。
- 原句/用途任一路失败（旧句没有用途的情况除外）都不会标记完成。重试不再生成句子、不再扣次数。
- 向量落库、主题匹配、完成任务在另一事务中一起提交；主题匹配失败时全部回滚并保留任务。
- 后台最多同时处理 8 组，每次唤起最多处理 3 组。失败重试间隔从 30 秒倍增到最多 15 分钟。
- 后续生成请求会顺带处理同账号待办；定时补偿暂缓，没有后续生成请求时，失败任务可能持续待处理。
- 完成后清空队列中的句子副本，保留轻量状态。删除回忆/账号会级联删除相应任务。
- 匿名恢复任务的 24 小时清理不删除未完成的向量任务，与现有匿名向量保留规则一致。
- 不自动补历史缺失向量，不更改主题的匹配阈值、收藏、学习进度和购买逻辑。

生成成功后立即打开主题时，新句子可能还未加入；后台完成后重新获取主题内容即可看到。
这里没有承诺固定缩短几秒，节省的是原先两路向量请求及落库/主题匹配的等待时间。

## 部署顺序

1. `Backend Database`：staging + apply，执行 `20260925001000_defer_generation_enrichment.sql`。
2. `Backend Functions`：staging，部署 `generate-memory-v2`。
3. 后台处理复用已有 `DASHSCOPE_API_KEY`、`DASHSCOPE_EMBEDDING_URL`，无新模型密钥。
4. 测试正常/匿名生成、立即登录迁移与主题刷新，确认任务由即时后台处理完成。
5. 完成 staging 验证后按相同顺序发布 production。

按用户要求，已删除每五分钟触发的 `Backend Enrichment Retry` workflow，不再定时调用函数。
不需要配置 `GENERATION_ENRICHMENT_SWEEPER_ENABLED`；如果此前已配置，该变量现在没有作用，可自行删除。
`process-generation-enrichment` 管理入口保留供后续使用，目前不要求部署，也不会自行运行。
主路径依靠 EdgeRuntime 后台任务处理。不需要调整代理，不需要更新 `recover-guest-generation`，
恢复接口只读取已经保存的结果，不应等待向量。客户端这次没有改动。

迁移后旧生成函数仍能使用相同 finalize 参数；在部署窗口内旧函数可能同步生成一次向量，
更新生成函数后后台再补一次，因此建议迁移完成后紧接着部署生成函数。旧 iOS 客户端无需更新。

## 排查

```sql
select status, count(*) from public.generation_enrichment_jobs group by status;

select id, memory_id, guest_job_id, status, attempts, next_attempt_at, lease_until, last_error
from public.generation_enrichment_jobs
where status <> 'completed'
order by created_at;
```

检查 Edge Function 的 `[generation-enrichment]` 日志，不记录句子全文或向量。
持续失败先核对百炼地址、密钥、实例出公网能力，再检查数据库错误。
`process-generation-enrichment` 仅接受 service-role Authorization，不允许客户端直接调用。
