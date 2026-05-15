# Client Environments

客户端通过 bundle 内的 plist 选择 Supabase 环境：

- Debug: 使用 `三句/Config.staging.plist`
- Release/App Store: 使用 `三句/Config.plist`

`STAGING` 编译条件目前只加在 Debug build configuration 上，所以 Xcode 直接 Run 到真机时会连接 staging；Archive 上传 TestFlight 或 App Store 时仍然连接 production。

## 当前地址

- staging: `https://api-staging.sanju.cc`
- production: `https://api.sanju.cc`

注意：客户端只允许放 `anon`/publishable key，不能放 `service_role` key。

## Staging 反向代理

staging 客户端入口现在也走 ECS/Nginx 转发，链路和 production 保持一致：

- client: `https://api-staging.sanju.cc`
- upstream: `spb-bp1364k407p37qn7.supabase.opentrust.net`

ECS 上需要有对应的 DNS、TLS 证书和 Nginx server block。反向代理结构可参考 `deploy/nginx/sanju-api-proxy.conf.example`，但要把 `server_name`、证书路径、`proxy_set_header Host`、`proxy_ssl_name` 和 upstream 都换成 staging 项目。
