#!/usr/bin/env bash
# 用法：build-number.sh <版本号>，输出“基础版本 构建号”。Android 的 versionCode 和 iOS 的构建号共用。
# 构建号与版本顺序一致：基础版本 ×100 + 后缀分（alpha N → N，beta N → 20+N，rc N → 50+N，正式版 → 99）。
# 例如 0.1.2-beta.1 → 10221，0.1.2-rc.1 → 10251，0.1.2 → 10299。
set -eu
VERSION="$1"
BASE="${VERSION%%-*}"
IFS=. read -r MAJOR MINOR PATCH <<< "$BASE"
PRE="${VERSION#"$BASE"}"; PRE="${PRE#-}"
KIND=$(echo "$PRE" | sed 's/[0-9.]*$//'); NUM=$(echo "$PRE" | sed 's/^[a-z]*\.\{0,1\}//'); NUM=${NUM:-0}
case "$KIND" in
  "") SUB=99 ;;
  rc) SUB=$((50 + NUM)) ;;
  beta) SUB=$((20 + NUM)) ;;
  *) SUB=$NUM ;;
esac
echo "$BASE $(( (MAJOR * 10000 + MINOR * 100 + PATCH) * 100 + SUB ))"
