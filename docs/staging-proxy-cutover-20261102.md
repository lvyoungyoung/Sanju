# Staging 中转服务器切换步骤

目标仅为 `api-staging.sanju.cc` → `spb-bp112jga6hk29sgb.supabase.opentrust.net`。
production 的域名、upstream、证书、部署 Secrets 一律不改。

## 当前进度与切流前提

数据库已通过 HTTPS 管理通道正式初始化并回读验证：30 张业务表、95 个函数、88 个迁移版本，账号和照片数据为空。基线和中转模板已随 GitHub 提交 `334c8a8`、`e78f02e` 推送。
2026-11-03：用户已反馈全部 19 个云函数部署成功；GitHub staging Secrets 已更新，模型/朗读/审核参数已配置；新实例邮箱登录和后台匿名会话已开启，Apple 登录保持关闭。Auth settings 和 REST 根接口只读检查 HTTP 200。客户端已更新新 anon key 并隔离新实例的本地数据，Xcode 专项测试通过。
**代理已切换。** 用户随后授权代为操作已登录的 ECS Workbench。已在实例 `i-0jl9976brhpqjey0dqkx` 的 `/etc/nginx/sites-enabled/default` 内，只替换 staging HTTPS server 的 5 处旧实例地址（Host、SNI、3 个 proxy_pass）；保留证书、超时及缓冲配置。production 和其他配置逐字节未变，完整 diff 已核对。执行 `nginx -t` 通过后，`systemctl reload nginx` 成功，服务状态为 `Result=success / active / running`，没有重启服务器。

切换前备份：ECS 上 `/root/sanju-nginx-before-staging-20261103-155002.conf`，权限 600。staging 块之外内容的 SHA-256 为 `f7459296e361e8b0bf7a08aebdfac596972e633d24e8cf1db8a8225f4df0006b`。因为该文件也含 production，未来回退前必须比较备份与当前文件，不能用过期整份备份覆盖后来独立修改的 production 配置。

通过 ECS 发起的无凭据、无写入检查：新实例直连和 staging 代理 `/auth/v1/health` 均 HTTP 401，TLS 校验结果为 0；代理 `/rest/v1/` 为 401（未提供 API key），`/storage/v1/status` 为 200，两个生成/朗读函数的 OPTIONS 为 405（处理器仅接受 POST）。这些只证明路由及服务响应，**不证明登录、生成或朗读业务成功**。本机随后访问直连和 staging 域名出现连接超时，原因未确定，不能据此归因于新实例或将公网客户端验收标为通过。证据截图：本机 `/private/tmp/sanju-staging-ecs-cutover-20261103.png`。

下一步使用包含客户端提交 `e542a73` 的 Debug 测试包验证匿名生成、邮箱注册/登录、照片、收藏、翻阅和朗读。此次切换不需要新增 migration 或再次部署函数。以下步骤保留为操作参考，不必重复执行切流。
不要再次执行专用空库初始化包，也不要用日常 migration 的 `baseline` 掩盖未部署步骤；后续新迁移正常执行。

## 1. 确认并备份现有 staging 配置

在 ECS 上查看有效配置，只定位 staging 的文件：

```bash
sudo nginx -T 2>/dev/null | grep -n -E 'configuration file|api-staging.sanju.cc|upstream|proxy_pass|proxy_ssl_name|proxy_set_header Host'
```

不要对输出涉及的全部文件做全局字符串替换。若 staging 与 production 共用一个 upstream，必须为 staging 新增独立 upstream，保留 production 的原引用。
将下面变量设为上一步查到的真实路径，不要把示例路径当成实际文件：

```bash
STAGING_CONF=/etc/nginx/conf.d/实际的staging配置.conf
sudo cp -a "$STAGING_CONF" "$STAGING_CONF.bak.$(date +%Y%m%d-%H%M%S)"
```

如果 upstream 定义在另一个文件，也先备份该文件。

## 2. 准备新实例访问白名单

确认 ECS 的实际公网出口 IPv4；不要仅把域名解析 IP 当成出口 IP。新实例初始 Web 白名单只有 127.0.0.1，因此只改 Nginx 会导致上游连接失败。
在阿里云后台对**新项目**设置 Web 白名单，保留现有值并加入 ECS 固定出口的单个 IP 或 /32。
用户排障时已临时加入 Web `0.0.0.0/0`。确认真实 ECS 固定出口及必要管理 IP 可访问后，移除此全网开放项；不要更改 production 或旧 staging。区分 Web（80/443）与数据库（5432）白名单；代理 HTTP 流量只需要 Web 访问，不因此放开数据库。
数据库初始化若由 ECS 执行，需要另行允许该 ECS 出口的数据库连接；此前批准的本机 /32 不自动覆盖 ECS。

## 3. 最小范围修改 staging 路由

参考 `deploy/nginx/sanju-staging-upstream.conf.example`，不是整份替换模板。只处理 staging：

```nginx
upstream sanju_staging_supabase_backend {
    server spb-bp112jga6hk29sgb.supabase.opentrust.net:443;
    keepalive 32;
}
```

在现有 `server_name api-staging.sanju.cc` 对应的 server 中使用：

```nginx
proxy_set_header Host spb-bp112jga6hk29sgb.supabase.opentrust.net;
proxy_ssl_server_name on;
proxy_ssl_name spb-bp112jga6hk29sgb.supabase.opentrust.net;
```

将这个 server 内所有实际代理路径的 `proxy_pass` 指向 `https://sanju_staging_supabase_backend`。
检查各 location 内是否还覆盖了旧 Host、TLS SNI 或 proxy_pass；Auth、REST、Storage、Functions 必须一致。
保留现有证书路径、重定向、请求头、上传限制及超时；保留朗读 SSE 的 `proxy_buffering off` / `proxy_cache off`，不要让 v2 语音被缓冲。

## 4. 先验证，后重载

确认上述部署、运行配置和访问条件就绪，且配置检查成功时才执行平滑重载，随后立即联调：

```bash
sudo nginx -t && sudo systemctl reload nginx
```

不需要重启 ECS、删除旧实例或更换 DNS/证书。若配置检查失败，不重载，先恢复备份或修正 staging 配置。

## 5. 同步其余配置并验收

- GitHub staging environment：SUPABASE_PROJECT_ID、SUPABASE_API_URL、SUPABASE_API_KEY（新 service_role）、SUPABASE_DB_PASSWORD。production environment 不变，密钥不写进 Nginx。
- 新实例运行环境：配置模型、朗读、审核和购买验签等实际使用的服务端凭据，使用新实例自身 Supabase 内置 key，不照搬旧实例内置值。只支持邮箱登录，Apple 登录保持关闭。
- 部署 `scripts/edge-functions.txt` 中全部 19 个函数，遵守数据库先完成、函数后部署的顺序。
- 客户端 Debug 包：使用新 anon key，并为新的空实例隔离 session、待同步队列及本地持久化命名空间；只改代理不改 key 不能正常使用，也不能把旧待同步内容导入新空库。
- 通过新测试安装验证登录/匿名生成、回忆、收藏、照片存储、朗读、恢复和删除。不要用真实购买来验证迁移。

## 回退

保留旧 staging。仅恢复 staging 文件的备份并校验/重载，同时恢复匹配旧实例的客户端 key 与命名空间。
不要把新实例中的 session、待同步内容发给旧库；不要回滚 production，也不要直接删除新库来掩盖失败。
