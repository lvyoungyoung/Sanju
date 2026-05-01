# ECS 入口反向代理 RDS Supabase 方案

这份方案适用于当前三句的正式上线架构：

```text
App -> api.yourdomain.com (ECS + EIP + Nginx) -> 阿里云 RDS Supabase
```

它解决的核心问题有两个：

- 移动端用户的 Wi-Fi / 蜂窝出口 IP 不固定，不能直接拿来配数据库白名单。
- `0.0.0.0/0` 只适合测试期，正式环境不应该长期这么开。

## 为什么这套方案适合当前项目

当前客户端所有后端请求都统一走一个 `SupabaseURL`，也就是：

- `/auth/v1/*`
- `/rest/v1/*`
- `/storage/v1/*`
- `/functions/v1/*`

所以只要把这一个入口换成你的 ECS API 域名，客户端代码不需要大改。

当前客户端配置位置：

- [Config.plist](/Users/young/Documents/Documents%20-%20吕扬’s%20Mac%20mini/iOS%20Development/三句/三句/Config.plist)
- [SupabaseService.swift](/Users/young/Documents/Documents%20-%20吕扬’s%20Mac%20mini/iOS%20Development/三句/三句/SupabaseService.swift)

## 最终推荐结构

推荐把官网和 API 放在同一台 ECS 上，但用不同子域名：

- 官网：`www.yourdomain.com`
- API：`api.yourdomain.com`

这样做的好处：

- 官网和 API 分流清楚
- 证书、日志、调试都更省心
- 后续备案接入关系也更清晰

## 实施步骤

### 1. 给 ECS 绑定 EIP

如果这台 ECS 还没有固定公网 IP，先绑定 EIP。

后面要做的白名单控制是：

- RDS Supabase 白名单里只放 ECS 的 **EIP**
- 不再放普通移动用户的出口 IP

### 2. 新增一个 API 子域名

例如：

- `api.yourdomain.com`

DNS 解析到这台 ECS 的 EIP。

### 3. 在 ECS 上配置 Nginx

模板文件已经放好了：

- [sanju-api-proxy.conf.example](/Users/young/Documents/Documents%20-%20吕扬’s%20Mac%20mini/iOS%20Development/三句/deploy/nginx/sanju-api-proxy.conf.example)

你需要替换的只有这些地方：

- `server_name api.example.com`
- 两条证书路径

当前上游地址已经按现有项目填好：

- `spb-bp103246ivn7q0nl.supabase.opentrust.net`

### 4. 给 API 子域名配 HTTPS

建议：

- `api.yourdomain.com`
- 单独配 TLS 证书

如果你已经在官网上用 Nginx 跑 HTTPS，这一步通常就是再加一个 `server` 块。

### 5. 调整 RDS Supabase 白名单

把白名单从临时测试用的：

- `0.0.0.0/0`

收紧成：

- 只允许 ECS 的 EIP

如果后续这套 RDS Supabase 形态支持内网访问，也可以再进一步改成：

- ECS 走内网访问
- 完全不走公网白名单

### 6. 切换客户端入口

把客户端的：

- `SupabaseURL`

从：

- `https://spb-bp103246ivn7q0nl.supabase.opentrust.net`

改成：

- `https://api.yourdomain.com`

当前配置文件：

- [Config.plist](/Users/young/Documents/Documents%20-%20吕扬’s%20Mac%20mini/iOS%20Development/三句/三句/Config.plist)

## 上线前核对项

### 必须验证

- 邮箱注册
- 邮箱登录
- 忘记密码验证码邮件
- 匿名生成后登录自动同步
- 回忆图片上传
- 云端回忆详情补图
- IAP 到账确认
- 删除账号

### Nginx 层建议确认

- 80 自动跳 443
- `client_max_body_size` 足够上传图片
- `/functions/v1/` 超时足够长
- `/storage/v1/` 已关闭缓冲，避免大图拖慢入口层

## 推荐验证命令

配置完成后，可以先在 ECS 上用这些方式验证：

### 检查 Nginx 配置

```bash
sudo nginx -t
```

### 重载配置

```bash
sudo systemctl reload nginx
```

### 验证 API 入口是否通

```bash
curl -i https://api.yourdomain.com/auth/v1/user
```

如果返回：

- `401 Unauthorized`

通常说明入口链路已经通了，只是没有带登录凭证，这个结果是正常的。

## 当前阶段建议

### 测试期

- 可以暂时保留 `0.0.0.0/0`
- 先把 ECS 入口调通

### 上线前

- 客户端切到 `api.yourdomain.com`
- RDS 白名单只保留 ECS 的 EIP

## 这套方案的边界

它不是把数据库“完全藏起来”，而是把数据库入口收敛到一个固定服务器上。

也就是说：

- 用户手机不再直连 RDS Supabase
- 白名单只管理 ECS
- 公开流量的第一层入口变成你自己的 Nginx

对当前三句来说，这是比“长期开放 `0.0.0.0/0`”更适合正式上线的方案。
