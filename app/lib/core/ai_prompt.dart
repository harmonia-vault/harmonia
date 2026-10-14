// 交给 AI 助手的安装提示词（docs/rewrite-plan.md 5.13）：与实例首页的那段相同，App 里还可以带上邮箱和配对码。
const _feed = 'https://github.com/harmonia-vault/harmonia/releases/download/update-feed';

/// 各个系统通用的提示词：介绍 Harmonia，让 AI 助手安装命令行、读取 harmonia skill 的说明并接入 [server]。
/// 给出 [email] 和 [code] 时直接写进去，AI 助手不必再向用户询问。
String aiInstallPrompt(String server, {String? email, String? code}) {
  final login = email != null && code != null
      ? '按输出的说明接入服务器 $server，邮箱是 $email，配对码是 $code（只能用一次；失效时请用户在手机上重新生成）'
      : '按输出的说明接入服务器 $server（邮箱和配对码向用户询问）';
  return 'Harmonia（和弦，$server）是用户部署的环境变量同步服务，开源、自托管：用户在手机 App 上管理 API Key 等环境变量，'
      '端到端加密后同步到用户授权的电脑，你可以用它的命令行取用这些变量，不需要用户把 Key 贴进对话。'
      '请在这台电脑上安装 Harmonia 命令行：macOS、Linux 运行 curl -fsSL $_feed/install.sh | HARMONIA_YES=0 sh；'
      "Windows 在 PowerShell 中运行 \$env:HARMONIA_YES = '0'; irm $_feed/install.ps1 | iex。"
      '装好后运行 harmonia skill，$login，并询问用户是否开启 Shell 集成和后台服务。';
}
