# Harmonia CLI 安装脚本（Windows）：按更新渠道下载当前处理器对应的 harmonia.exe，校验 SHA-256，
# 放到 %LOCALAPPDATA%\Programs\Harmonia 并加入用户的 Path。不需要管理员权限。
#   irm https://github.com/harmonia-vault/harmonia/releases/download/update-feed/install.ps1 | iex
#   安装测试版：先运行 $env:HARMONIA_CHANNEL = 'beta'
#
# 这个文件必须保存为不带 BOM 的 UTF-8，文字一律放在单引号里并经过 T：
# Windows PowerShell 5.1 的 irm 会把 UTF-8 的中文按单字节读错，T 把读错的文字还原。
& {
  $ErrorActionPreference = 'Stop'
  $ProgressPreference = 'SilentlyContinue'

  function T([string]$s) {
    if ($s -match '[^\x00-\xff]') { return $s }
    [Text.Encoding]::UTF8.GetString([Text.Encoding]::GetEncoding(28591).GetBytes($s))
  }
  function Say([string]$s) { Write-Host (T $s) }

  try {
    $feed = if ($env:HARMONIA_FEED) { $env:HARMONIA_FEED } else { 'https://github.com/harmonia-vault/harmonia/releases/download/update-feed' }
    $channel = if ($env:HARMONIA_CHANNEL) { $env:HARMONIA_CHANNEL } else { 'stable' }
    $dir = if ($env:HARMONIA_BIN_DIR) { $env:HARMONIA_BIN_DIR } else { Join-Path $env:LOCALAPPDATA 'Programs\Harmonia' }
    if ($channel -ne 'stable' -and $channel -ne 'beta') {
      throw (T 'HARMONIA_CHANNEL 只能是 stable（正式版）或 beta（测试版）。')
    }
    # 在 64 位系统上用 32 位或模拟的 PowerShell 运行时，以系统本身的处理器架构为准。
    $cpu = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    $arch = switch ($cpu) {
      'AMD64' { 'amd64' }
      'ARM64' { 'arm64' }
      default { throw ((T '暂不支持这个处理器架构：') + $cpu) }
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    try {
      $manifest = Invoke-RestMethod "$feed/$channel.json" -UseBasicParsing
    } catch {
      throw (T '无法获取更新信息（这个渠道可能还没有发布过版本，或者网络不通）。')
    }
    $asset = $manifest.assets."cli-windows-$arch"
    if (-not $asset) { throw ((T '这个版本没有提供 Windows 的安装包：') + $arch) }

    New-Item -ItemType Directory -Force $dir | Out-Null
    $exe = Join-Path $dir 'harmonia.exe'
    $new = Join-Path $dir 'harmonia-new.exe'
    Write-Host ((T '正在下载 harmonia ') + $manifest.version + " (windows/$arch) ...")
    Invoke-WebRequest $asset.url -OutFile $new -UseBasicParsing
    if ((Get-FileHash $new -Algorithm SHA256).Hash.ToLower() -ne $asset.sha256) {
      Remove-Item $new
      throw (T '校验失败：下载的文件与发布清单不一致，已停止安装。')
    }
    # 重新安装时旧程序可能正在运行（后台服务），不能直接覆盖，先改名让出位置。
    $again = Test-Path $exe
    if ($again) {
      Remove-Item "$exe.old" -ErrorAction SilentlyContinue
      Move-Item $exe "$exe.old" -Force
    }
    Move-Item $new $exe -Force
    Write-Host ((T '已安装到 ') + $exe + ' (' + (& $exe version) + ')')

    # 把安装目录加入用户的 Path，保留原有条目和类型。
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    $entries = @(([string]$key.GetValue('Path', '', 'DoNotExpandEnvironmentNames')).Split(';') | Where-Object { $_ })
    $present = $entries | Where-Object { [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\') -ieq $dir.TrimEnd('\') }
    if (-not $present) {
      $kind = if ($key.GetValueNames() -contains 'Path') { $key.GetValueKind('Path') } else { [Microsoft.Win32.RegistryValueKind]::ExpandString }
      $key.SetValue('Path', (($entries + $dir) -join ';'), $kind)
      # 删除一个不存在的变量：借此通知系统“环境变量已变化”，之后新开的终端就能直接运行 harmonia。
      [Environment]::SetEnvironmentVariable('HARMONIA_PATH_REFRESH', $null, 'User')
      $env:Path = "$dir;$env:Path"
    }
    $key.Close()

    if ($channel -eq 'beta') {
      & $exe update channel beta | Out-Null
      Say '已设置为测试版渠道，之后 harmonia update 会继续获取测试版。'
    }

    cmd /c 'schtasks /query /tn Harmonia >nul 2>&1'
    $service = $LASTEXITCODE -eq 0
    if ($again) {
      # 重新安装：之前的选择保持不变，只让后台服务换成新版本。
      if ($service) { & $exe service install }
      Say '已更新。'
    } elseif ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
      # 有终端可以交互时，询问是否开启写入用户环境变量和后台服务，直接回车即同意。
      Write-Host ''
      Say '[1/2] 用户环境变量：把同步的变量写入 Windows 的用户环境变量，新启动的程序都能读到。'
      Write-Host ''
      & $exe shell install
      Write-Host ''
      Say '[2/2] 后台服务：登录后自动运行，保持与服务器的连接，变量有变化时实时写入本机。'
      Write-Host ''
      $answer = Read-Host (T '是否安装后台服务？（Y/n）')
      if ($answer -match '^\s*(n|no)\s*$') {
        Say '已跳过。之后可以运行 harmonia service install。'
      } else {
        & $exe service install
        if ($LASTEXITCODE -ne 0) { Say '后台服务没有安装成功，可以稍后运行 harmonia service install 重试。' }
      }
      Write-Host ''
      Say '下一步：运行 harmonia login <服务器地址>'
    } else {
      Say '提示：运行 harmonia shell install 把变量写入用户环境变量，运行 harmonia service install 安装后台服务。'
      Say '下一步：运行 harmonia login <服务器地址>'
    }
  } catch {
    Write-Host ((T '安装没有完成：') + $_.Exception.Message) -ForegroundColor Red
  }
}
