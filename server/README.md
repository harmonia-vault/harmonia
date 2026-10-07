> [!WARNING]
> 项目处于早期版本（v0.x），请先用于非关键密钥。

# Harmonia 服务端

Harmonia（和弦）是一个自托管的环境变量同步工具：在手机上集中管理 API Key 等环境变量，授权给电脑、服务器和 AI Agent 环境使用。

这里是它的服务端，部署在你自己的 Cloudflare 账号上（Workers + Durable Objects）。服务端只保存密文：变量在手机或电脑上加密后才上传，服务端无法读取。

手机 App 与命令行工具见 [harmonia-vault/harmonia](https://github.com/harmonia-vault/harmonia)。

> 本仓库由主仓库的 `server/` 目录自动发布，请到主仓库提交问题和改动。

## 部署前准备

1. 一个 Cloudflare 账号（免费套餐即可）。
2. （可选）邮件验证码：在 Cloudflare 中启用 [Email Service](https://developers.cloudflare.com/email-service/) 并验证发信域名，然后设置 `EMAIL_FROM`。Email Service 需要付费套餐。
   - 不配置时（默认）：注册不验证邮箱，“找回密码”和“重置账号”不可用；其余功能不受影响，个人使用通常不需要。
   - 配置后可以把 `REQUIRE_EMAIL_VERIFICATION` 设为 `true`，要求注册时验证邮箱。

## 部署

仓库里不需要改任何文件，所有配置都在 Cloudflare 控制台填写。

1. [Fork 本仓库](https://github.com/harmonia-vault/harmonia-worker/fork)。
2. 在 Cloudflare 控制台 **Workers & Pages → Create → Import a repository**，选择你的 Fork。Worker 名称保持默认的 `harmonia-worker`（必须与仓库中的名称一致，否则构建失败；Fork 时也请保留仓库名），其余保持默认，部署。
3. （可选）需要修改默认配置时，打开这个 Worker 的 **Settings → Variables and Secrets**，按下表添加变量（类型选 Text），保存后立即生效。
4. 记下 Worker 的 HTTPS 地址（例如 `https://harmonia-worker.<你的子域>.workers.dev`），也可以在 Worker 设置中绑定自己的域名。
5. **立即**在手机 App 中填写这个地址并注册账号。`ALLOW_REGISTRATION` 未开启时，只有第一个注册的账号能成功，之后注册自动关闭。

## 配置

在 Worker 的 **Settings → Variables and Secrets** 中设置；不设置时使用默认值。重新部署不会覆盖这里的值。

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `EMAIL_FROM` | 空 | 发件地址，例如 `noreply@example.com`，域名需已在 Email Service 验证。为空时不发送邮件，“找回密码”和“重置账号”不可用 |
| `ALLOW_REGISTRATION` | `false` | 设为 `true` 开放注册。`false` 时只允许注册第一个账号；之后重置过的账号可以用同一邮箱重新注册 |
| `REQUIRE_EMAIL_VERIFICATION` | `false` | 设为 `true` 时注册需要验证邮箱（需要先配置 `EMAIL_FROM`） |

每个账号的数据相互隔离，存放在各自的 Durable Object 中。

## 更新

在你的 Fork 页面点击 **Sync fork → Update branch**，Cloudflare 会自动重新部署。配置和数据都会保留：配置在控制台中，服务端带有表结构迁移。

App 或命令行提示“服务器版本过旧”时，按此方法更新即可。

## 删除全部数据

在 Cloudflare 控制台删除这个 Worker，它的 Durable Object 数据会随之删除；之后可以重新部署一个全新的实例。这会删除所有账号的数据，且无法恢复。

只想清空某一个账号时，在 App 登录页选择“重置账号”，通过邮件验证码确认即可。

## 安全说明

- 服务端只保存密文、设备公钥和权限信息；变量值、环境密钥都在客户端加密。
- 服务端负责执行权限：降权、撤销、到期在服务端立即生效。
- 服务端被攻破时，攻击者无法直接读取变量值，但可以拒绝服务、回滚数据，或假装执行撤销。详见主仓库的安全说明。

## 本地开发

```bash
pnpm install
pnpm test                       # 单元测试（Node + node:sqlite）
pnpm dev                        # 本地运行（workerd，http://localhost:8787），验证码打印在日志中，不发送邮件
```

## 许可证

[MIT](LICENSE)
