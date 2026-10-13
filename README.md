> [!WARNING]
> 项目处于早期版本（v0.x），请先用于非关键密钥。

# Harmonia / 和弦

Harmonia 是一个自托管的环境变量同步工具：在手机上集中管理 API Key 等环境变量，授权给自己的电脑、服务器和 AI Agent 环境使用。配置一次，所有设备自动同步，不用反复手工填写，也不用把 Key 贴进 AI 对话。

- **端到端加密**：变量在手机或电脑上加密后才上传，服务端只保存密文。
- **手机负责授权**：新电脑扫码配对，由手机决定它能访问哪些环境、只读还是读写、多久到期；随时撤销。
- **终端中使用**：安装 Shell 集成后自动加载变量；也可以用 `harmonia exec` 只给某个程序注入。
- **AI 助手一句话部署**：把一句提示词发给 Claude Code、Codex 这类 AI 助手，它在电脑上装好命令行并接入，你只需在手机上批准，见[在电脑上接入](#3-在电脑上接入)。
- **实时同步**：手机上改一次，几秒内同步到在线的电脑。
- **自托管**：服务端部署在你自己的 Cloudflare 账号上，开源（MIT）。

## 组成

| 组件 | 说明 |
| --- | --- |
| 服务端（`server/`） | Cloudflare Workers + Durable Objects，发布在 [harmonia-worker](https://github.com/harmonia-vault/harmonia-worker) 供 Fork 部署 |
| App（`app/`） | Android 与 iPhone，管理环境与变量、批准和移除设备、恢复账号 |
| 命令行（`cli/`） | macOS、Linux 与 Windows，在电脑、服务器上同步并注入变量 |

## 快速开始

### 1. 部署服务端

按 [harmonia-worker 的说明](https://github.com/harmonia-vault/harmonia-worker) 部署到 Cloudflare（Fork 后在 Cloudflare 控制台导入，配置在控制台填写，无需改文件），记下 HTTPS 地址。部署后请立即注册第一个账号。

### 2. 安装 App 并创建账号

1. 从 [Releases](https://github.com/harmonia-vault/harmonia/releases/latest) 下载安装包：Android 下载 `harmonia-<版本>-android-arm64.apk`（现代 ARM64 手机）直接安装，旧款仅支持 32 位的设备下载 `harmonia-<版本>-android-arm.apk`；iPhone 见下面的[在 iPhone 上安装](#在-iphone-上安装)。
2. 打开 App，填写服务器地址（也可以在电脑浏览器里打开服务器地址，用 App 的“扫码填写”扫页面上的二维码），输入邮箱注册（账号没有密码；服务端开启了邮箱验证时，还要输入邮件中的验证码）。
3. App 会生成**恢复码**：请抄在纸上或存进密码管理器。丢失所有手机时，只有它能找回数据。
4. 新建环境（例如“OpenAI”），添加变量（例如 `OPENAI_API_KEY`）。

#### 在 iPhone 上安装

Harmonia 没有上架 App Store。Releases 里的 `harmonia-<版本>.ipa` 没有签名，需要你自己签名后安装（iOS 16 及以上）：

1. 下载 `harmonia-<版本>.ipa`。
2. 用 AltStore、SideStore 这类自签工具，或者自己的 Apple 开发者证书签名并安装。

需要知道的几件事：

- 用免费 Apple ID 签名的 App 7 天后过期，要在过期前重新签名（上述工具可以自动续签）。过期后 App 打不开，重新签名后数据还在。
- 换一个 Apple ID 或证书签名，系统会把它当成另一个 App，原来的数据读不到，需要按新手机重新接入（由管理设备批准，或用恢复码恢复）。
- 卸载后重装、从备份恢复、换机迁移之后，同样需要重新接入。

### 3. 在电脑上接入

**推荐让 AI 助手来做。** 把下面这句话发给 Claude Code、Codex 这类能运行命令的 AI 助手，macOS、Linux、Windows 都用这一句（换成你的服务器地址）。在电脑浏览器里打开服务器地址，首页“接入电脑”一步也有这句话，地址已经填好，点“复制”即可：

```text
在这台电脑上安装 Harmonia 命令行：macOS、Linux 运行 curl -fsSL https://github.com/harmonia-vault/harmonia/releases/download/update-feed/install.sh | HARMONIA_YES=1 sh；Windows 在 PowerShell 中运行 $env:HARMONIA_YES = '1'; irm https://github.com/harmonia-vault/harmonia/releases/download/update-feed/install.ps1 | iex。装好后运行 harmonia skill，按输出的说明接入服务器 https://你的服务器地址（邮箱和配对码问我）。
```

- `HARMONIA_YES=1` 让安装脚本不再询问，直接装好 Shell 集成和后台服务（Windows 上是写入用户环境变量和后台服务）。
- `harmonia skill` 输出给 AI 助手的使用说明：怎样接入、用 `harmonia exec` 使用变量、不把变量值打印出来、哪些命令要你同意才运行。`harmonia skill install` 把它保存成技能文件，写到 `~/.claude/skills` 和 `~/.agents/skills`（对应的工具目录存在时），或用 `--dir` 指定的目录。
- 接入时 AI 助手会向你要邮箱和配对码（在 App 的“设备 → 添加设备 → 生成配对码”中获取），并把核对码告诉你，由你在手机上批准。
- `harmonia update` 会顺带更新保存过的技能文件。说明里写着对应的版本，AI 助手发现版本对不上时会重新读取。

#### 自己安装

macOS、Linux：

```bash
curl -fsSL https://github.com/harmonia-vault/harmonia/releases/download/update-feed/install.sh | sh
```

系统里没有 `curl` 时（例如刚装好的 Ubuntu 桌面版），把 `curl -fsSL` 换成 `wget -qO-`。

Windows（在 PowerShell 里运行，不需要管理员权限，见下面的“Windows”一节）：

```powershell
irm https://github.com/harmonia-vault/harmonia/releases/download/update-feed/install.ps1 | iex
```

然后：

```bash
harmonia login https://你的服务器地址
```

安装过程中会询问是否安装 Shell 集成和后台服务，直接回车即安装。Shell 集成支持 Bash 5.1 及以上、Zsh 5.0 及以上；已有终端按安装提示加载一次，新终端自动启用。跳过的话，之后可以运行 `harmonia shell install` 和 `harmonia service install`。

命令会询问邮箱和配对码，不需要密码。配对码可以留空：终端会显示二维码，在 App 中打开“设备 → 添加设备”扫码（或手输终端里的核对码），选择这台电脑可以访问的环境和权限，批准。也可以先在 App 的“添加设备”里点“生成配对码”，把 8 位配对码填进去，这样手机在前台时会直接弹出批准页；批准前同样要核对核对码。授权的环境默认已启用。

之后在手机上修改变量，同步完成后，电脑终端按一次空回车即可使用新值；直接执行的第一条命令可能仍使用旧值。在 App 的“设备详情”里可以开关某个环境、拖动调整顺序。

### Windows

Windows 10（1809 及以上）、Windows 11 都可以用，系统自带的 Windows PowerShell 和 PowerShell 7 都能运行安装命令。程序装在 `%LOCALAPPDATA%\Programs\Harmonia`，安装后新开一个终端即可使用 `harmonia`。

Windows 上没有 Shell 集成，变量写入的是系统的**用户环境变量**（“系统属性 → 环境变量”里的用户变量）：

- 安装时会询问是否开启，之后用 `harmonia shell install`、`harmonia shell uninstall` 开关。
- 开启后，**新启动**的程序都能读到变量，包括 cmd、PowerShell 和图形界面程序。已经打开的终端和程序不会变，变量同步后要新开终端；想在当前终端马上用到最新值，用 `harmonia exec -- <命令>`。
- 已有的同名用户变量会先记下原值，变量删除、环境停用、退出登录或卸载之后恢复。
- `Path`、`TEMP` 这类系统自身使用的变量默认不写入，`harmonia status` 会列出。确实需要时，在 App 里这台电脑的“设备详情”中打开“写入系统变量”，或运行 `harmonia shell system-vars on`。
- 值以明文保存在当前用户的注册表里，这台电脑上你启动的所有程序都能读到。
- 不要直接删除程序文件来卸载：请用 `harmonia uninstall`，它会把写入的用户环境变量恢复原状。

后台服务是一个名为“Harmonia”的计划任务，登录 Windows 后自动在后台运行，没有窗口。

程序没有做代码签名。用上面的命令安装不会被拦截；如果是从 Releases 页面用浏览器下载 `harmonia-windows-amd64.exe`（ARM 电脑下载 `arm64`），运行时 Windows 可能提示“已保护你的电脑”，可以先用 `Get-FileHash` 算出 SHA-256，与同一个 Release 里 `manifest.json` 中的值核对后再运行。

在 WSL 里使用时，请在 WSL 内安装 Linux 版，它和 Windows 版是两台各自独立的设备。

## 常用命令

```text
harmonia status                       查看接入状态、环境、后台服务
harmonia env list                     列出可访问的环境、顺序和同名变量
harmonia env deactivate <环境>        停用环境（activate 重新启用）
harmonia env order <环境>...          调整顺序：同名变量由排在前面的环境提供
harmonia exec -- <命令>               只给这个命令注入变量
harmonia exec --env OpenAI,Other -- <命令>
harmonia export --format dotenv       输出当前生效的变量
harmonia var set <环境> <变量名>       写入变量（需要读写权限，必须联网）
harmonia import --env <环境>          从当前终端勾选已有的环境变量导入
harmonia override set <环境> <变量名> <值>
                                      设置只在本机生效的值，不上传
harmonia update                       升级 harmonia
harmonia skill                        输出给 AI 助手的使用说明（install 保存成技能文件）
harmonia logout                       退出账号，清除本机数据
harmonia uninstall                    完全卸载
```

## 在 AI Agent 和常驻服务中使用

shell 启动文件只对终端生效。systemd、launchd、cron 启动的程序不会读取它，可以用下面的方式：

Windows 上开启“写入用户环境变量”后，登录之后新启动的程序都能直接读到变量；需要保证拿到最新值的程序，同样可以用 `harmonia exec` 启动。

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

- **App（Android）**：在“设置 → 检查更新”中升级，也会每天自动检查一次，自动选择当前架构的安装包。安装包经过签名校验，数据保留。`0.3.1-rc.10` 起按架构分包，此前版本需要从 Releases 下载对应 APK 覆盖安装一次，请勿卸载；之后继续应用内更新。
- **App（iPhone）**：“设置 → 检查更新”会提示新版本。点“下载并导入签名工具”，在弹出的面板里选择安装时使用的签名工具（轻松签、全能签、万能签等），再用它和同一个 Apple ID（或证书）签名安装即可，数据保留。也可以点“打开下载页”自己下载。
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

Windows：

```powershell
$env:HARMONIA_CHANNEL = 'beta'; irm https://github.com/harmonia-vault/harmonia/releases/download/update-feed/install.ps1 | iex
```

从测试版切回正式版时不会降级，正式版发布更高的版本后再自动升级。

## 常见问题

**密码在哪里？** 账号没有密码。新设备接入时由你的管理设备批准（扫码，或用管理设备生成的一次性配对码），丢失所有管理设备时用恢复码恢复。知道你邮箱的人只能发起一个你看不到的配对请求，你不扫码就不会接入。

**手机丢了？** 用另一台管理设备移除它；没有其他管理设备时，在新手机上输入邮箱后选择“用恢复码恢复”，之后会要求更换恢复码。

**恢复码和手机全丢了？** 只能在输入邮箱页选择“重置账号”（需要服务端配置了发信），删除这个账号的全部数据后重新开始；没有配置发信时，在 Cloudflare 控制台删除 Worker 后重新部署。

**终端里拿不到变量？** 用 `harmonia status` 查看环境是否启用及同步状态，Shell 集成的启用方式见[在电脑上接入](#3-在电脑上接入)。

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
