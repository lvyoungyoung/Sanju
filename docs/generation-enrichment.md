# 生成后的后台向量与主题匹配

## 请求链路

`generate-memory-v2` 仍等待审核、MiMo/Kimi 返回、图片保存和 finalize 数据库事务。
finalize 在同一事务保存结果、扣一次额度，并写入 `generation_enrichment_jobs`。
接口随后返回原来的 JSON，不再等待向量服务和主题匹配。

每句的分类 ID 和表达用途仍随模型生成返回，并非再调用一次模型；移到后台的是
原句/用途两组向量，以及依据这些向量把句子加入学习主题的数据库计算。

后台使用 `EdgeRuntime.waitUntil`，独立的数据库客户端和 45 秒预算，不沿用生成请求的
90 秒截止时间，也不依赖手机继续连接。运行时不支持后台保活时不退回同步等待，任务留给补偿 worker。
参考：[Supabase background tasks](https://supabase.com/docs/guides/functions/background-tasks)。

## 完整性与重试

- 成功生成和扣次的事务边界、请求幂等、旧客户端三句返回格式不变。入队失败时整个事务回滚。
- 匿名结果和向量任务都使用稳定句子 ID。向量先到或登录迁移先到，均由现有 promotion 触发器接入登录账号。
- 任务领取有两分钟租约；进程被终止后可以重新领取。过期 worker 不能覆盖新 worker 的结果。
- 原句/用途任一路失败（旧句没有用途的情况除外）都不会标记完成。重试不再生成句子、不再扣次数。
- 向量落库、主题匹配、完成任务在另一事务中一起提交；主题匹配失败时全部回滚并保留任务。
- 后台最多同时处理 8 组，每次唤起最多处理 3 组。失败重试间隔从 30 秒倍增到最多 15 分钟。
- 后续生成请求会顺带处理同账号待办；独立 worker 定时兜底没有后续请求、运行时中断或暂时网络故障。
- 完成后清空队列中的句子副本，保留轻量状态。删除回忆/账号会级联删除相应任务。
- 匿名恢复任务的 24 小时清理不删除未完成的向量任务，与现有匿名向量保留规则一致。
- 不自动补历史缺失向量，不更改主题的匹配阈值、收藏、学习进度和购买逻辑。

生成成功后立即打开主题时，新句子可能还未加入；后台完成后重新获取主题内容即可看到。
这里没有承诺固定缩短几秒，节省的是原先两路向量请求及落库/主题匹配的等待时间。

## 部署顺序

1. `Backend Database`：staging + apply，执行 `20260925001000_defer_generation_enrichment.sql`。
2. `Backend Functions`：staging，部署 `process-generation-enrichment` 和 `generate-memory-v2`。
3. 新 worker 需要与生成函数相同的 `DASHSCOPE_API_KEY`、`DASHSCOPE_EMBEDDING_URL`，复用已有配置，无新模型密钥。
4. GitHub Settings → Environments → staging → Variables：添加 `GENERATION_ENRICHMENT_SWEEPER_ENABLED=true`。
   `Backend Enrichment Retry` 每五分钟尝试补偿，复用该环境已有 `SUPABASE_API_URL` 和 `SUPABASE_API_KEY` Secrets。
   仅推送代码不会启用补偿，也不会部署。未启用时只有生成请求触发的后台处理，不能保证空闲期自动重试。
5. 手动运行一次 `Backend Enrichment Retry`，选择 staging，确认 HTTP 200；再测试正常/匿名生成、立即登录迁移与主题刷新。
6. 完成 staging 验证后按相同顺序发布 production，并单独开启 production 的上述变量。

定时任务是重试兜底，不是主路径；GitHub 定时任务可能延迟，ECS runner 离线时也不能执行。
主路径依靠 EdgeRuntime 后台任务及时处理。不需要调整代理，不需要更新 `recover-guest-generation`，
恢复接口只读取已经保存的结果，不应等待向量。客户端这次没有改动。

迁移后旧生成函数仍能使用相同 finalize 参数；在部署窗口内旧函数可能同步生成一次向量，
随后 worker 再补一次，因此建议先部署 worker，再紧接着部署生成函数。旧 iOS 客户端无需更新。

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
