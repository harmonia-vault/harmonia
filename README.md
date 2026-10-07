> [!WARNING]
> 项目处于早期版本（v0.x），请先用于非关键密钥。

# Harmonia / 和弦

Harmonia 是一个自托管的环境变量同步工具：在手机上集中管理 API Key 等环境变量，授权给自己的电脑、服务器和 AI Agent 环境使用。配置一次，所有设备自动同步，不用反复手工填写，也不用把 Key 贴进 AI 对话。

- **端到端加密**：变量在手机或电脑上加密后才上传，服务端只保存密文。
- **手机负责授权**：新电脑扫码配对，由手机决定它能访问哪些环境、只读还是读写、多久到期；随时撤销。
- **按普通方式注入**：变量写进一个由 Harmonia 维护的 `env.sh`，在 shell 启动文件末尾加载，和你平时设置环境变量的方式一样；也可以用 `harmonia exec` 只给某个程序注入。
- **实时同步**：手机上改一次，在线的电脑几秒内生效。
- **自托管**：服务端部署在你自己的 Cloudflare 账号上，开源（MIT）。

## 组成

| 组件 | 说明 |
| --- | --- |
| 服务端（`server/`） | Cloudflare Workers + Durable Objects，发布在 [harmonia-worker](https://github.com/harmonia-vault/harmonia-worker) 供 Fork 部署 |
| Android App（`app/`） | 管理环境与变量、批准和移除设备、恢复账号 |
| 命令行（`cli/`） | macOS 与 Linux，在电脑、服务器上同步并注入变量 |

## 快速开始

### 1. 部署服务端

按 [harmonia-worker 的说明](https://github.com/harmonia-vault/harmonia-worker) 部署到 Cloudflare（Fork 后在 Cloudflare 控制台导入，配置在控制台填写，无需改文件），记下 HTTPS 地址。部署后请立即注册第一个账号。

### 2. 安装 App 并创建账号

1. 从 [Releases](https://github.com/harmonia-vault/harmonia/releases/latest) 下载 `harmonia-<版本>.apk` 安装。
2. 打开 App，填写服务器地址，用邮箱注册（服务端开启了邮箱验证时，还要输入邮件中的验证码）。
3. App 会生成**恢复码**：请抄在纸上或存进密码管理器。丢失所有手机时，只有它能找回数据。
4. 新建环境（例如“OpenAI”），添加变量（例如 `OPENAI_API_KEY`）。

### 3. 在电脑上接入

```bash
curl -fsSL https://github.com/harmonia-vault/harmonia/releases/download/update-feed/install.sh | sh
```

```bash
harmonia login https://你的服务器地址
```

终端会显示二维码。在 App 中打开“设备 → 添加设备”扫码，选择这台电脑可以访问的环境和权限，批准。

```bash
harmonia env activate OpenAI          # 在本机启用环境
harmonia shell install                # 新开的终端自动带上变量
harmonia service install              # 后台服务：实时同步，开机自动运行
```

之后在手机上修改变量，电脑上新开的终端会拿到新值。

## 常用命令

```text
harmonia status                       查看接入状态、环境、后台服务
harmonia env list                     列出可访问的环境
harmonia env activate <环境> --priority 10
                                      启用多个环境时，同名变量以优先级数值大的为准
harmonia exec -- <命令>               只给这个命令注入变量
harmonia exec --env OpenAI,Other -- <命令>
harmonia export --format dotenv       输出当前生效的变量
harmonia var set <环境> <变量名>       写入变量（需要读写权限，必须联网）
harmonia import --env <环境>          从当前终端勾选已有的环境变量导入
harmonia override set <环境> <变量名> <值>
                                      设置只在本机生效的值，不上传
harmonia update                       升级 harmonia
harmonia logout                       退出账号，清除本机数据
harmonia uninstall                    完全卸载
```

## 在 AI Agent 和常驻服务中使用

shell 启动文件只对终端生效。systemd、launchd、cron 启动的程序不会读取它，可以用下面的方式：

**直接包一层 `harmonia exec`**（推荐）：

```bash
harmonia exec -- python agent.py
```

**systemd 服务**：

```ini
[Service]
ExecStart=/home/me/.local/bin/harmonia exec -- /usr/bin/node /srv/agent/index.js
```

`harmonia exec` 启动时会先同步一次；连不上服务器时使用本机缓存。

**launchd（macOS）**：在 `ProgramArguments` 前面加上 `harmonia` 的路径与 `exec`、`--` 两个参数。

已经在运行的程序不会拿到新值，需要重启它。

## 安全说明

**能保证的：**

- 服务端只保存密文。数据库泄露或云厂商都读不到变量值。
- 服务端被完全控制，也拿不到明文——前提是你没有批准一台假设备。配对时会核对设备的公钥指纹（二维码或 16 位核对码），所有环境密钥的发放都由账号密钥签名。
- 降权、撤销、删除在服务端立即生效；被移除的设备联网后会自动清除本机数据，离线设备最晚在授权到期时停用。

**不保证的：**

- 变量下发到设备后，风险由使用者承担：同一用户的任何进程（包括 AI Agent）都能读到注入的变量和 `~/.harmonia/env.sh`。撤销收不回已经复制或泄露的值，必要时请到服务商处更换密钥。
- 手机被他人拿到并解开锁屏不在防护范围内，请用另一台管理设备或恢复码移除它。
- 服务端被攻破时，可能拒绝服务、回滚数据，或假装执行撤销。
- 服务端能看到变量名、环境名、设备名和访问时间。
- **恢复码等于整个账号。** 恢复码泄露，别人就能接管账号；恢复码和所有手机都丢失，数据无法找回。

## 升级

- **App**：在“设置 → 检查更新”中升级，也会每天自动检查一次。安装包经过签名校验，数据保留。
- **命令行**：`harmonia update`。后台服务每天检查一次，有新版本时 `harmonia status` 会提示。
- **服务端**：在你的 Fork 中点击 Sync fork。

### 更新渠道

| 渠道 | 收到的版本 |
| --- | --- |
| 正式版（默认） | 只有正式版本，例如 `v0.1.2` |
| 测试版 | 全部版本中最新的一个，包括 `v0.1.3-rc.1`、`v0.1.3-beta.2` 这类测试版本 |

版本顺序：`v0.1.2` > `v0.1.2-rc.1` > `v0.1.2-beta.1`。在 App 的“设置 → 更新渠道”中切换；命令行使用 `harmonia update channel beta`（或 `stable`）。安装测试版命令行：

```bash
curl -fsSL https://github.com/harmonia-vault/harmonia/releases/download/update-feed/install.sh | HARMONIA_CHANNEL=beta sh
```

从测试版切回正式版时不会降级，正式版发布更高的版本后再自动升级。

## 常见问题

**忘记密码？** 在登录页选择“忘记密码”，通过邮件验证码设置新密码，数据不受影响（需要服务端配置了发信）。没有配置发信时，用“用恢复码恢复”也可以设置新密码。

**手机丢了？** 用另一台管理设备移除它；没有其他管理设备时，在新手机上登录后选择“用恢复码恢复”，之后会要求更换恢复码。

**密码、恢复码、手机全丢了？** 只能在登录页选择“重置账号”（需要服务端配置了发信），删除这个账号的全部数据后重新开始；没有配置发信时，在 Cloudflare 控制台删除 Worker 后重新部署。

**终端里拿不到变量？** 确认已运行 `harmonia env activate` 和 `harmonia shell install`，并新开一个终端；用 `harmonia status` 查看同步状态。

## 开发

工具链由根目录 `mise.toml` 管理：

```bash
mise install
mise run test        # 三端单元测试
mise run e2e         # 端到端流程：本地 workerd + 真实 CLI + 无界面管理设备
mise run dev-server  # 本地运行服务端
```

设计与协议见 [docs/](docs/)。

## 许可证

[MIT](LICENSE)
