---
name: harmonia
description: 用 Harmonia 命令行（harmonia）读取、使用和修改从用户手机同步到这台电脑的环境变量，例如 API 密钥、访问令牌。需要用到某个密钥或环境变量、运行依赖这些变量的命令、写入或修改变量，或者用户提到 Harmonia（和弦）时使用。
---

# Harmonia 命令行

本说明对应 harmonia {{version}}。

Harmonia 让用户在手机上管理环境变量，同步到电脑。变量按“环境”分组，用户在手机上决定这台电脑能访问哪些环境，以及只读还是可以修改。

## 读取最新说明

本说明由 harmonia 程序输出，随程序一起升级。要保存成技能文件时运行 `harmonia skill install`（技能目录不是 `~/.claude` 或 `~/.agents` 时，加 `--dir <技能目录>`）：它只写一个入口文件，让你每次使用前运行 `harmonia skill` 读取当时的说明，程序升级后不会过期。不要把本说明的全文复制进技能文件或项目文档。

本说明是在会话开始时读取的。会话中途程序可能被后台升级，如果命令报错说选项或用法不对，运行 `harmonia skill` 或 `harmonia <命令> --help` 重新查看。

找不到 `harmonia` 命令时：macOS、Linux 上试 `~/.local/bin/harmonia`，Windows 上试 `%LOCALAPPDATA%\Programs\Harmonia\harmonia.exe`。都没有的话，按下一节安装。

## 安装

macOS、Linux：

```bash
curl -fsSL https://github.com/harmonia-vault/harmonia/releases/download/update-feed/install.sh | HARMONIA_YES=0 sh
```

Windows（PowerShell）：

```powershell
$env:HARMONIA_YES = '0'; irm https://github.com/harmonia-vault/harmonia/releases/download/update-feed/install.ps1 | iex
```

`HARMONIA_YES=0` 让安装脚本不再询问，只装命令行本身，不装 Shell 集成和后台服务。这两项由你在装好后询问用户，见下一节；不要用 `HARMONIA_YES=1` 替用户决定。

## 询问是否开启 Shell 集成和后台服务

装好后，向用户解释下面两项，分别问是否开启；用户同意哪项再运行哪项的命令。不论开不开，`harmonia exec -- <命令>` 都能用，接入账号前开启也没问题。用 `harmonia status` 查看两项当前的状态。

**Shell 集成**（Windows 上叫“写入用户环境变量”）

- 作用：macOS、Linux 上在 shell 启动文件（`~/.zshenv`、`~/.bashrc`）里加几行，用户自己打开的终端自动带上已启用环境的变量，变量有变化时按一次回车即可使用新值。Windows 上把变量写进用户环境变量，新启动的程序（包括图形界面程序）都能读到。
- 不开启时：终端和其他程序里没有这些变量，需要时用 `harmonia exec -- <命令>` 只给这一条命令注入，或用 `harmonia export` 输出。
- 区别：开启后最省事，在任何终端里直接用；但变量会出现在每个终端（Windows 上是每个新程序）的环境里，同一用户运行的任何程序都能读到，Windows 上还以明文保存在注册表里。不开启时只有通过 `harmonia exec` 启动的程序拿得到变量，范围更小。
- 开启：`harmonia shell install --yes`（默认按当前 shell；需要时加 `--shell zsh` 或 `--shell bash`）。关闭：`harmonia shell uninstall`，只在用户要求时运行。
- 开启后，用户已经打开的终端要按命令输出的提示加载一次，或者新开一个终端。

**后台服务**

- 作用：开机（macOS、Windows 上是登录）后在后台运行，保持与服务器的连接：用户在手机上修改变量、授权或撤销这台电脑时，几秒内同步到本机；授权到期后及时停用；每天检查一次新版本。
- 不开启时：只在运行 `harmonia exec`、`harmonia export`、`harmonia sync` 这类命令时才同步。Shell 集成里的变量要等下一次同步才会更新；手机上撤销这台电脑或授权到期后，本机的变量也要等下一次同步才清除。
- 区别：开启后变量始终是最新的，撤销也最快生效，代价是一个常驻的后台进程。只用 `harmonia exec` 的话，不开启也能用，因为它每次启动时都会先同步。
- 开启：`harmonia service install`。Linux 上如果输出提示运行 `sudo loginctl enable-linger ...`，说明退出登录后服务会停止，把这条命令和原因转告用户，由用户决定是否运行；不要自己运行 sudo。关闭：`harmonia service uninstall`，只在用户要求时运行。

## 接入账号（需要用户在手机上批准）

先运行 `harmonia status`。已经接入账号时不要再运行 `harmonia login`。

接入只能由用户在手机上批准，你不能自己完成：

1. 向用户要服务器地址和注册 Harmonia 用的邮箱，并请用户在手机 App 的“设备 → 添加设备 → 生成配对码”中生成一个 8 位配对码（默认 10 分钟内有效）。
2. 运行：

   ```bash
   harmonia login <服务器地址> --email <邮箱> --code <配对码> --name <设备名>
   ```

   设备名用能让用户认出这台电脑的名字，例如主机名。所有参数都给出时命令不会提问。
3. 命令会打印核对码，然后等待批准，最长 5 分钟。把核对码和设备名告诉用户，请用户在手机上核对一致后批准，并选择这台电脑可以访问的环境。等待期间不要结束这条命令：放到后台运行，或者把命令超时设为 6 分钟以上。
4. 提示被拒绝或过期时，请用户重新生成配对码，再运行一次。

没有配对码时可以不给 `--code`，但用户就得用手机扫描终端里的二维码，或者手输核对码，比较麻烦。

## 查看

```bash
harmonia status                   # 接入状态、环境、Shell 集成和后台服务
harmonia env list                 # 能访问的环境、顺序、ID，以及同名变量由哪个环境提供
harmonia var list [--env 环境]    # 变量名，默认隐藏值
```

除非用户明确要求查看某个值，不要使用 `--show`。

不确定某条命令的参数时，运行 `harmonia <命令> --help`（例如 `harmonia var --help`），它只输出用法，不执行命令。

## 使用变量

用 `harmonia exec` 运行需要这些变量的命令，变量只注入给这条命令，值不会出现在输出里：

```bash
harmonia exec -- python agent.py
harmonia exec --env 环境A,环境B -- npm test   # 只用这些环境，排在前面的优先
harmonia exec --env 环境A --env 环境B -- npm test   # 同上，--env 也可以重复给出
harmonia exec --env 环境A,环境C:API_KEY -- npm test   # 环境A 的全部变量，加上环境C 里的 API_KEY
```

- 用户要求只用某个或某几个环境（例如测试环境、生产环境）时用 `--env`：命令只拿到这些环境的变量，即使当前终端里已有其他环境的变量。环境名用 `harmonia env list` 查。
- 只需要某个环境里的个别变量时写成 `环境:变量名`，同一环境要多个变量就写多项（`环境C:A,环境C:B`）；指定的变量不存在时命令不会运行，并提示怎样查看。
- 环境既可以用名称也可以用 ID 指定（`harmonia env list` 的 ID 列）。把命令写进脚本、CI 或配置文件时用 ID：环境改名后 ID 不变。
- 不要假设当前 shell 里已经有这些变量。Shell 集成主要作用于用户自己的终端，你执行命令的 shell 不一定加载它。
- `harmonia exec` 启动时先同步一次；连不上服务器时使用本机缓存，并在 stderr 提示。`harmonia status`、`harmonia env list`、`harmonia var list` 也是这样。
- 这台设备没有任何环境的访问权限时，`harmonia exec` 照常运行命令，只在 stderr 提示拿不到变量。这时请用户在管理设备上为这台设备授权。
- 不要把变量值打印到对话里：避免 `echo $KEY`、`env`、`harmonia export`、`harmonia var list --show`。
- 确实要把变量写进文件（例如 `.env`）时，先征得用户同意，并确认这个文件不会被提交到版本库。`harmonia export --format dotenv|sh|json` 输出当前生效的变量，加 `--env` 时只输出这些环境的变量，用法与 `harmonia exec` 相同。

## 修改变量（需要读写权限，必须联网）

把值从标准输入传进去，不要写在命令参数里（参数会留在 shell 历史和进程列表中）：

```bash
printf '%s' "$VALUE" | harmonia var set <环境> <变量名>
harmonia var set <环境> <变量名> < value.txt
harmonia var rm <环境> <变量名>
```

- 从标准输入只读取第一行，首尾空白会被去掉。
- 变量可以带一条备注，说明用途或来源，会在 `harmonia var list` 中显示。给了 `--note` 时命令不读取标准输入，只改备注、保留原值，所以分两步：先按上面的方式写入值，再运行 `harmonia var set <环境> <变量名> --note 备注`。`--note ""` 清除备注。不要把密钥写进备注。
- 删除变量、覆盖已有的值之前，先向用户确认。
- 提示只有只读权限时，告诉用户需要在手机上把这台电脑对这个环境的权限改为读写。

只想在这台电脑上用另一个值、不改动其他设备时，用本机覆盖（不上传）：

```bash
printf '%s' "$VALUE" | harmonia override set <环境> <变量名>
harmonia override rm <环境> <变量名>
harmonia override list
```

`harmonia import` 要逐个勾选，需要交互输入，不适合你使用；改用 `harmonia var set`。

## 环境的启用和顺序

`harmonia env activate|deactivate <环境>`、`harmonia env order <环境>...` 会改变这台电脑上所有程序拿到的变量，只在用户要求时使用。

## 需要用户明确要求才能运行的命令

下面这些命令会移除数据或改变安装，带 `--yes` 时不会再确认：

- `harmonia logout`：退出账号，清除本机的密钥和变量
- `harmonia uninstall`：完全卸载
- `harmonia shell uninstall`、`harmonia service uninstall`
- `harmonia update channel beta|stable`：切换更新渠道
- `harmonia update auto on|off`：开启或关闭自动更新
- `harmonia shell system-vars on|off`（只在 Windows 上）：是否把 `Path`、`TEMP` 这类系统自身使用的变量也写入用户环境变量，写错会影响这台电脑上的所有程序

不要读取或修改 `~/.harmonia` 里的文件，其中 `env.sh` 保存着明文的变量值。

## 不要使用管理登录

`harmonia manager` 下的命令（管理页面、管理登录、退出管理登录）让这台电脑能管理整个账号，只能由用户本人在终端和浏览器里操作。不要运行它们，不要代用户输入管理口令，也不要访问它在本机打开的页面和端口。用户问起时，告诉用户自己运行 `harmonia manager`。

## 升级

`harmonia update --check` 检查新版本，`harmonia update` 升级并重启后台服务。用户也可能开启了自动更新，或在手机上让这台电脑更新，这时程序会在后台换成新版本。升级后运行 `harmonia skill` 重新读取说明。

## 常见提示

- 本机还没有接入账号：按“接入账号”一节，请用户批准。
- 找不到环境：用 `harmonia env list` 查看准确的环境名。
- 这台设备已被移除：用户在手机上移除了这台电脑，需要的话重新接入。
- 暂时无法连接服务器：读取类命令使用本机缓存；写入类命令要等网络恢复。
