# GitHub Self-Hosted Runner

这份文档用于把后端 Edge Function 部署任务固定跑在阿里云 ECS 上，避免 GitHub hosted runner 直连阿里云 Supabase 管理接口时出现 TCP 超时。

## 用途

- GitHub 仍然负责编排 Actions。
- ECS 只负责执行部署命令。
- 阿里云 AnalyticDB Supabase 仍然是官方托管服务，不部署到 ECS。

## 安装 Runner

在 GitHub 仓库页面进入：

```text
Settings -> Actions -> Runners -> New self-hosted runner
```

选择：

```text
Linux -> x64
```

GitHub 会生成一组安装命令。建议在 ECS 上使用单独用户运行：

```bash
sudo adduser --disabled-password --gecos "" github-runner
sudo usermod -aG sudo github-runner
sudo su - github-runner
```

按 GitHub 页面给出的命令下载并解压 runner，然后执行配置命令时加上固定标签：

```bash
./config.sh \
  --url https://github.com/lvyoungyoung/Sanju \
  --token <github-generated-token> \
  --name sanju-aliyun-ecs \
  --labels aliyun-ecs \
  --unattended
```

`<github-generated-token>` 是 GitHub 页面生成的一次性 token，不要写进仓库或聊天记录。

配置完成后安装为 systemd 服务：

```bash
sudo ./svc.sh install github-runner
sudo ./svc.sh start
sudo ./svc.sh status
```

## GitHub Secrets

仓库需要配置：

```text
SUPABASE_API_URL=https://spb-bp103246ivn7q0nl.supabase.opentrust.net
SUPABASE_API_KEY=<service_role key>
```

位置：

```text
Settings -> Secrets and variables -> Actions
```

## 使用方式

进入：

```text
Actions -> Backend Functions -> Run workflow
```

先选择低风险函数测试：

```text
cleanup-guest-generation-jobs
```

确认成功后再部署其他函数或选择：

```text
all
```

## 维护命令

查看 runner 服务状态：

```bash
sudo systemctl status actions.runner.lvyoungyoung-Sanju.sanju-aliyun-ecs.service --no-pager
```

重启 runner：

```bash
sudo systemctl restart actions.runner.lvyoungyoung-Sanju.sanju-aliyun-ecs.service
```

如果服务名不同，先列出：

```bash
systemctl list-units "actions.runner.*"
```

## 安全注意

- 这台 ECS 会拥有部署生产 Edge Function 的能力。
- 不要在 runner 目录里保存额外密钥文件。
- 不要把 `service_role` key 写进代码、日志或文档。
- ECS 安全组只保留必要入口，SSH 建议限制来源 IP。
