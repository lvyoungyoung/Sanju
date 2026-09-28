# 稳定性问题修复与部署说明（2026-09-28）

## 修复范围

本轮针对夜间检查发现的五个已复现问题，以及购买回包跨账号的静态风险。
不改变生成内容、学习算法、购买额度、购买入账 RPC 或页面设计。

1. **回忆误合并**：`MemoryIdentity` 只按稳定的回忆 ID 匹配，不再按句子文本相等判断身份。
   当前生成、恢复、匿名迁移都保留同一回忆 ID。不同照片甚至同一照片的两次生成，都不会因为文本相同而被删除。
   新增相同文本不同照片、相同 ID 恢复、空句子和同图不同生成的回归测试，移除预期失败标记。
2. **旧系统析构崩溃**：给存在同类风险的主线程辅助对象显式声明非隔离析构，保留正常方法的主线程隔离。
   对有可取消任务的对象保持取消清理。新增同步 TaskLocal 上下文释放对象的专项回归。
   原理参考 Swift 官方 issue https://github.com/swiftlang/swift/issues/88036；本轮实际在 iOS 26.2 模拟器验证，不代表所有真机系统均已覆盖。
3. **清理权限**：`cleanup-guest-generation-jobs` 只接受 POST，并验证当前环境的 service-role Bearer 凭据。
   缺少凭据、普通用户凭据、错误凭据均在读取或删除数据前拒绝。
4. **清理失败冒充成功**：检查 Storage 和数据库删除结果；Storage 失败时保留任务，数据库失败时返回错误，允许重试。
   每批最多 100 条，避免大量 ID 组成过长 URL；计数取实际返回结果，`hasMore` 提示可继续下一批。
5. **匿名自迁移清零**：函数入口要求非匿名目标且源/目标不同；新增 SQL migration 在事务开始前拒绝空 ID 或相同 ID。
   保持现有余额、流水、重复迁移幂等行为及 service-role 执行权限。
6. **购买迟到回包**：增加购买会话作用域，退出、切换账号或同账号重新登录后，旧请求不能写当前余额、清除当前错误或错误结束交易。
   同账号正常刷新令牌不影响确认。失效回包保持交易可重试，服务端已确认的订单仍通过现有幂等逻辑恢复，不重复加次数。

同时补齐后端环境变量示例、发布清单和数据库/函数 CI 中的边界回归。

## 验证

本轮全部业务验证使用本地替身、内存 PostgreSQL 和隔离模拟器，没有调用 staging/production、真实模型或 Apple 购买接口。
模拟器测试产物使用回环服务地址、占位公开 key 和空商品列表，源配置不变。

| 对象 | 结果 |
| --- | --- |
| 当前工作区后端离线回归 | 123 项、91 子步骤通过 |
| 实际提交版本后端离线回归 | 118 项、91 子步骤通过 |
| 当前工作区 iOS 26.2 | 240 项通过，0 失败、0 预期失败 |
| 当前工作区 iOS 27 | 240 项通过，0 失败、0 预期失败，Xcode 退出码 0 |
| 实际提交版本独立构建 | Debug simulator build-for-testing 成功 |
| 实际提交版本 iOS 26.2 | 158 项通过，0 失败、0 预期失败 |
| 两个修改的 Edge Function | 类型检查通过 |

数量差异来自用户原有尚未提交的功能和测试：独立提交检查目录只包含 Git 中的本轮修复，没有夹带这些改动。
旧系统首次测试的设备准备失败已通过显式启动隔离模拟器解决。第一次完整运行又发现测试辅助对象 `PresentationState` 同样触发析构问题，补显式析构后重跑全量通过。
新增测试的 weak 变量警告已消除；仍可能出现系统音频 QoS、截图渲染诊断，它们不是本轮编译错误。
消除警告后的构建成功，旧系统析构专项再次通过。
iOS 27 的附加诊断收集停滞，确认进程归属及全部测试完成后，仅停止该诊断子进程；Xcode 随后正常封存结果并返回成功，未停止测试主进程。

本地证据：

- `/tmp/sanju-stability-fixes-ios26-final.xcresult`、`/tmp/sanju-stability-fixes-ios26-final.log`
- `/tmp/sanju-stability-fixes-ios27.xcresult`、`/tmp/sanju-stability-fixes-ios27.log`
- `/tmp/sanju-stability-committed-ios26.xcresult`
- `/tmp/sanju-stability-fixes-deno-final.log`、`/tmp/sanju-stability-committed-deno.log`
- `/tmp/sanju-stability-fixes-build-clean.log`、`/tmp/sanju-stability-deinit-final.log`

## 部署顺序

推送不等于部署，本轮不自动触发部署。

1. `Backend Database`：先 staging 执行 `apply`，新增 migration 为 `20260928000000_guard_guest_credit_transfer.sql`。
2. `Backend Functions`：更新 `migrate-guest-credits` 和 `cleanup-guest-generation-jobs`。
3. 本地重新 Run 客户端验证照片迁移、恢复、购买及账号切换。模拟器测试不是实际 StoreKit 结算验收。
4. staging 确认后再将相同版本发布到 production。

不需要更新 `generate-memory-v2`、`recover-guest-generation`、`confirm-purchase`，也不需要修改 Nginx。
不新增必填环境变量。清理的调用方必须使用已有 service-role 服务端凭据（不可放进 App），不能再用普通用户令牌。
清理返回 `hasMore=true` 可继续请求；没有新增定时器或补偿调度。

## 保留的边界

- 原有未提交 UI/功能代码保留。对其中几个未跟踪辅助类的同类析构修复保留在本地，未为了这几行夹带提交整套未发布功能。
- 本轮没有复现真实支付，也没有宣称所有支持的真机系统均通过。正式发布前仍需真机回归。
- 仓库缺少购买入账 RPC `confirm_purchase_atomically` 的创建定义，不能根据猜测重建覆盖线上。此项记录为基线文档缺口，需要获得授权后导出已有定义再补齐；本轮没有修改线上购买原子事务。
