# Staging 中转服务器切换步骤

目标仅为 `api-staging.sanju.cc` → `spb-bp112jga6hk29sgb.supabase.opentrust.net`。
production 的域名、upstream、证书、部署 Secrets 一律不改。

## 当前不要切流

数据库已通过 HTTPS 管理通道正式初始化并回读验证：30 张业务表、95 个函数、88 个迁移版本，账号和照片数据为空。基线和中转模板已随 GitHub 提交 `334c8a8`、`e78f02e` 推送。
云函数、Auth/运行密钥、GitHub staging Secrets 及客户端 key/独立数据空间仍未完成切换，REST 等端到端验收尚未通过，因此目前仍不要重载切流。
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
不要开放 0.0.0.0/0，不要更改 production 或旧 staging。区分 Web（80/443）与数据库（5432）白名单；代理 HTTP 流量只需要 Web 访问，不因此放开数据库。
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

只有后端验收已明确通过，且配置检查成功时才执行平滑重载：

```bash
sudo nginx -t && sudo systemctl reload nginx
```

不需要重启 ECS、删除旧实例或更换 DNS/证书。若配置检查失败，不重载，先恢复备份或修正 staging 配置。

## 5. 同步其余配置并验收

- GitHub staging environment：SUPABASE_PROJECT_ID、SUPABASE_API_URL、SUPABASE_API_KEY（新 service_role）、SUPABASE_DB_PASSWORD。production environment 不变，密钥不写进 Nginx。
- 新实例运行环境：配置模型、朗读、审核、Apple 登录/购买验签等所需服务端凭据，使用新实例自身 Supabase 内置 key，不照搬旧实例内置值。
- 部署 `scripts/edge-functions.txt` 中全部 19 个函数，遵守数据库先完成、函数后部署的顺序。
- 客户端 Debug 包：使用新 anon key，并为新的空实例隔离 session、待同步队列及本地持久化命名空间；只改代理不改 key 不能正常使用，也不能把旧待同步内容导入新空库。
- 通过新测试安装验证登录/匿名生成、回忆、收藏、照片存储、朗读、恢复和删除。不要用真实购买来验证迁移。

## 回退

保留旧 staging。仅恢复 staging 文件的备份并校验/重载，同时恢复匹配旧实例的客户端 key 与命名空间。
不要把新实例中的 session、待同步内容发给旧库；不要回滚 production，也不要直接删除新库来掩盖失败。
