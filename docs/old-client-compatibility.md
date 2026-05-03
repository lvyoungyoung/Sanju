# 旧客户端兼容测试

这套测试用于在更新后端后，快速确认旧版 App 依赖的接口契约没有被改坏。

## 使用场景

- 部署 Edge Functions 到 staging 后，先跑一遍兼容测试。
- 执行 SQL migration 后，先跑一遍兼容测试。
- 准备把 staging 的后端变更推到 production 前，先跑一遍兼容测试。

## 当前测试覆盖

脚本只做低风险检查，不会触发真实生成、真实购买或删除账号。

- 匿名登录、获取当前用户、刷新 session。
- profile upsert、fetch、patch。
- 匿名用户可用次数只能向下同步。
- memories 分页读取、回忆数量统计、收藏数量统计。
- 学习模块的 count / queue RPC。
- 恢复后台生成接口在 job 不存在时返回 `recovered=false`。
- `generate-memory-v2` 在缺少图片时返回稳定错误，不进入真实生成。
- 购买接口在没有登录时先返回鉴权错误，不进入 App Store 校验。

## 本地运行

默认读取 `三句/Config.staging.plist`，所以一般直接运行：

```bash
node scripts/check-client-compatibility.mjs
```

也可以显式指定 staging：

```bash
node scripts/check-client-compatibility.mjs --env staging
```

如果临时要测试别的 Supabase 项目，可以覆盖 URL 和 anon key：

```bash
SANJU_COMPAT_BASE_URL="https://<project>.supabase.opentrust.net" \
SANJU_COMPAT_ANON_KEY="<anon-key>" \
node scripts/check-client-compatibility.mjs
```

如果网络较慢，可以临时调大超时时间：

```bash
SANJU_COMPAT_TIMEOUT_MS=60000 node scripts/check-client-compatibility.mjs
```

## Production 安全锁

脚本默认拒绝对 production 运行，因为它会创建一个匿名测试用户和 profile。

如果确实要做 production smoke test，需要显式打开：

```bash
SANJU_COMPAT_ALLOW_PRODUCTION=1 node scripts/check-client-compatibility.mjs --env production
```

正常发布流程里，优先只对 staging 跑。

## 发布流程里的位置

推荐顺序：

1. 修改并提交后端代码或 migration。
2. 通过 GitHub Actions 部署到 `staging`。
3. 运行 `node scripts/check-client-compatibility.mjs`。
4. 用 Debug 包真机走一遍关键路径。
5. 确认没问题后，再通过 GitHub Actions 部署到 `production`。

## 怎么扩展成真正的旧版本测试

如果某个已上架版本有固定接口行为，可以把那一版客户端依赖的接口补进这个脚本。

原则是：

- 只断言旧客户端真正依赖的字段，不因为后端新增字段失败。
- 优先测试错误返回和空数据返回，因为这些最容易被后端重构改坏。
- 不在脚本里放 `service_role` key。
- 不调用删除账号、真实购买确认、真实生成这类不可逆或会消耗额度的动作。
