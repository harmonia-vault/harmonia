#!/bin/sh
# Harmonia CLI 安装脚本：下载并校验 harmonia，安装到 ~/.local/bin 并配置 PATH。
#   curl -fsSL https://github.com/harmonia-vault/harmonia/releases/download/update-feed/install.sh | sh
#   没有 curl 时：wget -qO- <同一个地址> | sh
#   安装测试版：在 sh 前加上 HARMONIA_CHANNEL=beta
#   不询问、直接安装 shell 集成和后台服务：在 sh 前加上 HARMONIA_YES=1
#   不询问、两项都不装（供 AI 助手使用，装好后由它询问用户）：在 sh 前加上 HARMONIA_YES=0
set -eu

FEED="${HARMONIA_FEED:-https://github.com/harmonia-vault/harmonia/releases/download/update-feed}"
CHANNEL="${HARMONIA_CHANNEL:-stable}"
DEST="${HARMONIA_BIN_DIR:-$HOME/.local/bin}"

case "$CHANNEL" in
  stable|beta) ;;
  *) echo "HARMONIA_CHANNEL 只能是 stable（正式版）或 beta（测试版）" >&2; exit 1 ;;
esac

os=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$os" in
  darwin|linux) ;;
  *) echo "暂不支持这个系统：${os}（目前支持 macOS 和 Linux）" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64|amd64) arch=amd64 ;;
  arm64|aarch64) arch=arm64 ;;
  *) echo "暂不支持这个处理器架构：$(uname -m)" >&2; exit 1 ;;
esac

# fetch <地址> <保存位置>：用 curl 下载，没有 curl 时用 wget。
if command -v curl >/dev/null 2>&1; then
  fetch() { curl -fsSL "$1" -o "$2"; }
elif command -v wget >/dev/null 2>&1; then
  fetch() { wget -q "$1" -O "$2"; }
else
  echo "需要 curl 或 wget 才能下载，请先安装其中一个。" >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fetch "$FEED/$CHANNEL.json" "$tmp/manifest.json" || {
  echo "无法获取更新信息（$CHANNEL 渠道可能还没有发布过版本）。" >&2
  exit 1
}
block=$(sed -n "/\"cli-$os-$arch\"/,/}/p" "$tmp/manifest.json")
url=$(echo "$block" | sed -n 's/.*"url": *"\([^"]*\)".*/\1/p')
expected=$(echo "$block" | sed -n 's/.*"sha256": *"\([0-9a-f]*\)".*/\1/p')
version=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$tmp/manifest.json" | head -1)
if [ -z "$url" ] || [ -z "$expected" ]; then
  echo "这个版本没有提供 $os/$arch 的安装包。" >&2
  exit 1
fi

echo "正在下载 harmonia ${version}（${os}/${arch}）……"
fetch "$url" "$tmp/harmonia"
if command -v sha256sum >/dev/null 2>&1; then
  actual=$(sha256sum "$tmp/harmonia" | cut -d' ' -f1)
else
  actual=$(shasum -a 256 "$tmp/harmonia" | cut -d' ' -f1)
fi
if [ "$expected" != "$actual" ]; then
  echo "校验失败：下载的文件与发布清单不一致，已停止安装。" >&2
  exit 1
fi

mkdir -p "$DEST"
chmod 755 "$tmp/harmonia"
mv "$tmp/harmonia" "$DEST/harmonia"
echo "已安装到 $DEST/harmonia（$("$DEST/harmonia" version)）"
if [ "$CHANNEL" = "beta" ]; then
  "$DEST/harmonia" update channel beta >/dev/null 2>&1 || true
  echo "已设置为测试版渠道，之后 harmonia update 会继续获取测试版。"
fi

# 安装器由管道里的 sh 执行；用用户的登录 shell 选择启动文件。
# 路径按单引号字面量写入，不能把目录名里的 $、反引号等当作代码。
quoted_dest="'$(printf '%s' "$DEST" | sed "s/'/'\\\\''/g")'"
path_export="export PATH=${quoted_dest}\"\${PATH:+:\$PATH}\""
path_line="case \":\${PATH-}:\" in *:${quoted_dest}:*) ;; *) ${path_export} ;; esac"
configure_path() {
  if [ -f "$1" ] && grep -Fqx "$path_line" "$1"; then
    return
  fi
  if ! { mkdir -p "$(dirname "$1")" && printf '\n# Harmonia CLI\n%s\n' "$path_line" >> "$1"; }; then
    printf '无法更新 %s，请检查文件权限后重新安装。\n' "$1" >&2
    exit 1
  fi
  printf '已配置命令路径：%s\n' "$1"
}

user_shell=${SHELL:-/bin/sh}
case "${user_shell##*/}" in
  zsh) configure_path "${ZDOTDIR:-$HOME}/.zshrc" ;;
  bash)
    configure_path "$HOME/.bashrc"
    # Bash 只读取第一个存在且可读的登录文件，不能新建文件遮住原配置。
    profile="$HOME/.profile"
    for candidate in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
      if [ -f "$candidate" ] && [ -r "$candidate" ]; then
        profile=$candidate
        break
      fi
    done
    configure_path "$profile"
    ;;
  sh) configure_path "$HOME/.profile" ;;
  *) printf '未自动配置 %s，请将 %s 加入该终端的 PATH。\n' "${user_shell##*/}" "$DEST" ;;
esac
# HARMONIA_YES=1 时不询问，直接安装 shell 集成和后台服务；HARMONIA_YES=0 时不询问，两项都不装；
# 否则有终端可以交互时询问，直接回车即安装；没有终端时只提示命令。
if [ "${HARMONIA_YES:-}" = 1 ]; then
  echo
  echo "[1/2] Shell 集成：在终端中自动加载和更新变量。"
  echo
  "$DEST/harmonia" shell install --yes </dev/null || echo "Shell 集成没有安装成功，可以稍后运行 harmonia shell install 重试。"
  echo
  echo "[2/2] 后台服务：开机自动运行，保持与服务器的连接，变量有变化时实时写入本机。"
  echo
  "$DEST/harmonia" service install </dev/null || echo "后台服务没有安装成功，可以稍后运行 harmonia service install 重试。"
  echo
elif [ "${HARMONIA_YES:-}" != 0 ] && (exec </dev/tty) 2>/dev/null; then
  echo
  echo "[1/2] Shell 集成：在终端中自动加载和更新变量。"
  echo
  "$DEST/harmonia" shell install </dev/tty || true
  echo
  echo "[2/2] 后台服务：开机自动运行，保持与服务器的连接，变量有变化时实时写入本机。"
  echo
  printf "是否安装后台服务？（Y/n）"
  ans=""
  read -r ans </dev/tty || true
  case "$ans" in
    n|N|no|NO|No) echo "已跳过。之后可以运行 harmonia service install。" ;;
    *) "$DEST/harmonia" service install </dev/tty || echo "后台服务没有安装成功，可以稍后运行 harmonia service install 重试。" ;;
  esac
  echo
else
  echo "提示：运行 harmonia shell install 启用终端变量，运行 harmonia service install 安装后台服务。"
fi
case ":$PATH:" in
  *":$DEST:"*) ;;
  *)
    echo
    case "${user_shell##*/}" in
      zsh|bash|sh)
        echo "当前终端先运行以下命令，即可使用 harmonia；新终端自动生效："
        printf '  %s\n' "$path_export"
        ;;
      *)
        printf '当前终端可用完整路径登录：\n  %s/harmonia login <服务器地址>\n' "$quoted_dest"
        exit 0
        ;;
    esac
    ;;
esac
echo
echo "下一步：运行 harmonia login <服务器地址>"
