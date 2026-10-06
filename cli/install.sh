#!/bin/sh
# Harmonia CLI 安装脚本：按更新渠道下载当前系统对应的 harmonia 到 ~/.local/bin，并校验 SHA-256。
#   curl -fsSL https://github.com/harmonia-vault/harmonia/releases/download/update-feed/install.sh | sh
#   安装测试版：在 sh 前加上 HARMONIA_CHANNEL=beta
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
  *) echo "暂不支持这个系统：$os（目前支持 macOS 和 Linux）" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64|amd64) arch=amd64 ;;
  arm64|aarch64) arch=arm64 ;;
  *) echo "暂不支持这个处理器架构：$(uname -m)" >&2; exit 1 ;;
esac

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

curl -fsSL "$FEED/$CHANNEL.json" -o "$tmp/manifest.json" || {
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

echo "正在下载 harmonia $version（$os/$arch）……"
curl -fsSL "$url" -o "$tmp/harmonia"
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

case ":$PATH:" in
  *":$DEST:"*) ;;
  *) echo "提示：$DEST 不在 PATH 中，请在 shell 配置文件中加入：export PATH=\"$DEST:\$PATH\"" ;;
esac
echo "下一步：运行 harmonia login <服务器地址>"
