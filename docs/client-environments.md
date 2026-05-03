# Client Environments

客户端通过 bundle 内的 plist 选择 Supabase 环境：

- Debug: 使用 `三句/Config.staging.plist`
- Release/App Store: 使用 `三句/Config.plist`

`STAGING` 编译条件目前只加在 Debug build configuration 上，所以 Xcode 直接 Run 到真机时会连接 staging；Archive 上传 App Store 时仍然连接 production。

## 当前地址

- staging: `https://spb-bp1364k407p37qn7.supabase.opentrust.net`
- production: `https://api.sanju.cc`

注意：客户端只允许放 `anon`/publishable key，不能放 `service_role` key。

## 后续可选优化

如果要让 staging 更贴近 production 的网络链路，可以在 ECS 上增加 `api-staging.sanju.cc` 反向代理，然后只需要把 `Config.staging.plist` 里的 `SupabaseURL` 改成 `https://api-staging.sanju.cc`。
