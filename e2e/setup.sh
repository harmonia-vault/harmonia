# 端到端测试的公共部分：变量、断言、启动本地服务端和推送中继、调用 CLI 和无界面管理脚本的函数。
# 由 run.sh 引入，不单独运行。
# shellcheck shell=bash
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP="$ROOT/e2e/.tmp"
PORT=8799
SERVER="http://localhost:$PORT"
RELAY_PORT=8797
RELAY="http://localhost:$RELAY_PORT"
EMAIL="e2e-$RANDOM@example.com"

rm -rf "$TMP" && mkdir -p "$TMP"
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
fail() { printf '\033[31m失败：%s\033[0m\n' "$*"; exit 1; }
expect_eq() { [ "$1" == "$2" ] || fail "$3：期望 [$2]，实际 [$1]"; }
# expect_has 输出 模式 说明：先拿到完整输出再匹配，避免 grep -q 提前退出让管道失败。
expect_has() { grep -qE -- "$2" <<<"$1" || fail "$3：$1"; }

cleanup() {
  [ -n "${DAEMON_PID:-}" ] && kill "$DAEMON_PID" 2>/dev/null || true
  [ -n "${MGR_PID:-}" ] && kill "$MGR_PID" 2>/dev/null || true
  [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null || true
  [ -n "${RELAY_PID:-}" ] && kill "$RELAY_PID" 2>/dev/null || true
  pkill -f "wrangler dev.*$PORT" 2>/dev/null || true
  pkill -f "wrangler dev.*$RELAY_PORT" 2>/dev/null || true
}
trap cleanup EXIT

step "构建 CLI、无界面管理脚本与启动本地服务端、推送中继"
(cd "$ROOT/cli" && go build -o "$TMP/harmonia" ./cmd/harmonia)
# 管理脚本要调用几十次，先编译好，免得每次 dart run 都重新检查和编译。
(cd "$ROOT/app" && dart build cli --target tool/manager.dart --output "$TMP/manager" --verbosity error)
(cd "$ROOT/server" && npx wrangler dev --local --port $PORT --persist-to "$TMP/wrangler" \
  --var DEV_MAIL_LOG:true --var ALLOW_REGISTRATION:true --var REQUIRE_EMAIL_VERIFICATION:true --var DEV_RELAXED_LIMITS:true \
  --var DEV_PUSH_RELAY_URL:$RELAY \
  >"$TMP/server.log" 2>&1) &
SERVER_PID=$!
disown $SERVER_PID
for _ in $(seq 1 60); do curl -sf "$SERVER/api/v1/instance" >/dev/null && break; sleep 1; done
curl -sf "$SERVER/api/v1/instance" >/dev/null || fail "服务端没有启动，见 $TMP/server.log"
# 两个 wrangler dev 同时启动会抢同一个内部端口，等服务端起来再启动中继。
# 中继配置了自定义域名，本地运行时请求的主机名会被改成它；--local-upstream 让中继看到的仍是 localhost。
(cd "$ROOT/relay" && npx wrangler dev --local --port $RELAY_PORT --local-upstream localhost:$RELAY_PORT \
  --persist-to "$TMP/relay" --var DEV_FAKE_SENDER:true >"$TMP/relay.log" 2>&1) &
RELAY_PID=$!
disown $RELAY_PID
for _ in $(seq 1 60); do curl -s "$RELAY/" >/dev/null && break; sleep 1; done
curl -s "$RELAY/" >/dev/null || fail "推送中继没有启动，见 $TMP/relay.log"

manager() { (cd "$ROOT/app" && "$TMP/manager/bundle/bin/manager" --home "$TMP/$1" "${@:2}"); }
# 等推送中继的日志里出现发给这台手机的某类通知（DEV_FAKE_SENDER 把要发的通知写进日志）。
expect_push() {
  for _ in $(seq 1 50); do
    grep -aq "\[harmonia dev-push\] platform=android type=$1 token=e2e-push-token" "$TMP/relay.log" && return
    sleep 0.1
  done
  fail "$2：推送中继没有收到 $1 通知，见 $TMP/relay.log"
}
mail_code() { grep -a "to=$EMAIL purpose=$1" "$TMP/server.log" | tail -1 | sed 's/.*code=//'; }
cli() { HARMONIA_HOME="$TMP/cli" "$TMP/harmonia" "$@"; }
