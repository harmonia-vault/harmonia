#!/bin/sh
# Harmonia CLI 安装脚本：下载当前系统对应的 harmonia 到 ~/.local/bin，并校验 SHA-256。
#   curl -fsSL https://github.com/harmonia-vault/harmonia/releases/latest/download/install.sh | sh
set -eu

BASE="${HARMONIA_DOWNLOAD:-https://github.com/harmonia-vault/harmonia/releases/latest/download}"
DEST="${HARMONIA_BIN_DIR:-$HOME/.local/bin}"

os=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$os" in
  darwin|linux) ;;
  *) echo "暂不支持这个系统：$os（目前支持 macOS 和 Linux）" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64|amd64) arch=amd64 ;;
  arm64|aarch64) arch=arm64 ;;
  *) echo "暂不支持这个处理器架构：$(uname -m)" >&2; exit 1 ;;
esac

name="harmonia-$os-$arch"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "正在下载 $name ……"
curl -fsSL "$BASE/$name" -o "$tmp/harmonia"
curl -fsSL "$BASE/manifest.json" -o "$tmp/manifest.json"

expected=$(sed -n "/\"cli-$os-$arch\"/,/}/p" "$tmp/manifest.json" | sed -n 's/.*"sha256": *"\([0-9a-f]*\)".*/\1/p')
if command -v sha256sum >/dev/null 2>&1; then
  actual=$(sha256sum "$tmp/harmonia" | cut -d' ' -f1)
else
  actual=$(shasum -a 256 "$tmp/harmonia" | cut -d' ' -f1)
fi
if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
  echo "校验失败：下载的文件与发布清单不一致，已停止安装。" >&2
  exit 1
fi

mkdir -p "$DEST"
chmod 755 "$tmp/harmonia"
mv "$tmp/harmonia" "$DEST/harmonia"
echo "已安装到 $DEST/harmonia（$("$DEST/harmonia" version)）"

case ":$PATH:" in
  *":$DEST:"*) ;;
  *) echo "提示：$DEST 不在 PATH 中，请在 shell 配置文件中加入：export PATH=\"$DEST:\$PATH\"" ;;
esac
echo "下一步：运行 harmonia login <服务器地址>"
