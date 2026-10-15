# Harmonia 命令行

这是入口文件，不含完整说明。完整的使用说明由 harmonia 程序输出，随程序一起升级（包括后台自动升级）。每次开始使用 Harmonia 前先运行：

```
harmonia skill
```

按它输出的说明操作，不要凭记忆或本文件猜测命令和选项。

找不到 `harmonia` 命令时：macOS、Linux 上试 `~/.local/bin/harmonia`，Windows 上试 `%LOCALAPPDATA%\Programs\Harmonia\harmonia.exe`。都没有的话，这台电脑还没有安装，先安装再运行上面的命令：

- macOS、Linux：`curl -fsSL https://github.com/harmonia-vault/harmonia/releases/download/update-feed/install.sh | HARMONIA_YES=0 sh`
- Windows（PowerShell）：`$env:HARMONIA_YES = '0'; irm https://github.com/harmonia-vault/harmonia/releases/download/update-feed/install.ps1 | iex`
