#!/usr/bin/env bash
# 端到端流程测试：本地 workerd 服务端 + 真实 harmonia CLI + 无界面管理设备（app/lib/core）。
# 覆盖：注册验证、首次初始化、电脑配对（含取消等待）、exec、实时推送、写入、本地覆盖、权限变更、撤销、恢复与轮换、多管理设备。
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP="$ROOT/e2e/.tmp"
PORT=8799
SERVER="http://localhost:$PORT"
EMAIL="e2e-$RANDOM@example.com"
PASSWORD="correct horse battery"

rm -rf "$TMP" && mkdir -p "$TMP"
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
fail() { printf '\033[31m失败：%s\033[0m\n' "$*"; exit 1; }
expect_eq() { [ "$1" == "$2" ] || fail "$3：期望 [$2]，实际 [$1]"; }

cleanup() {
  [ -n "${DAEMON_PID:-}" ] && kill "$DAEMON_PID" 2>/dev/null || true
  [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null || true
  pkill -f "wrangler dev.*$PORT" 2>/dev/null || true
}
trap cleanup EXIT

step "构建 CLI 与启动本地服务端"
(cd "$ROOT/cli" && go build -o "$TMP/harmonia" ./cmd/harmonia)
(cd "$ROOT/server" && npx wrangler dev --local --port $PORT --persist-to "$TMP/wrangler" \
  --var DEV_MAIL_LOG:true --var ALLOW_REGISTRATION:true --var REQUIRE_EMAIL_VERIFICATION:true \
  >"$TMP/server.log" 2>&1) &
SERVER_PID=$!
disown $SERVER_PID
for _ in $(seq 1 60); do curl -sf "$SERVER/api/v1/instance" >/dev/null && break; sleep 1; done
curl -sf "$SERVER/api/v1/instance" >/dev/null || fail "服务端没有启动，见 $TMP/server.log"

manager() { (cd "$ROOT/app" && dart run tool/manager.dart --home "$TMP/$1" "${@:2}" 2> >(perl -pe 'BEGIN{$|=1} s/Running build hooks\.\.\.//g' >&2)); }
mail_code() { grep -a "to=$EMAIL purpose=$1" "$TMP/server.log" | tail -1 | sed 's/.*code=//'; }
cli() { HARMONIA_HOME="$TMP/cli" "$TMP/harmonia" "$@"; }

step "J1 注册、验证邮箱、首次初始化"
REG=$(manager phone register --server "$SERVER" --email "$EMAIL" --password "$PASSWORD")
expect_eq "$(printf %s "$REG" | cut -f1)" "verification-required" "注册"
sleep 1
manager phone verify --server "$SERVER" --email "$EMAIL" --flow "$(printf %s "$REG" | cut -f2)" --code "$(mail_code verification)" >/dev/null
RECOVERY=$(manager phone setup --server "$SERVER" --email "$EMAIL" --password "$PASSWORD" --name "主手机")
[[ "$RECOVERY" =~ ^[0-9A-HJKMNP-TV-Z]{4}(-[0-9A-HJKMNP-TV-Z]{1,4}){6}$ ]] || fail "恢复码格式：$RECOVERY"
manager phone env-create OpenAI >/dev/null
manager phone env-create Other >/dev/null
manager phone var-set OpenAI OPENAI_API_KEY "sk-first 'quoted' \$(no)" >/dev/null

step "J3 终端取消等待后，请求立即作废"
echo "$PASSWORD" | HARMONIA_HOME="$TMP/cli-cancel" "$TMP/harmonia" login "$SERVER" --email "$EMAIL" --password-stdin --name "e2e-cancel" \
  >/dev/null 2>"$TMP/cancel.err" &
CANCEL_PID=$!
CODE=""
for _ in $(seq 1 60); do
  CODE=$(grep -ao '核对码：[0-9A-HJKMNP-TV-Z-]*' "$TMP/cancel.err" | sed 's/核对码：//' || true)
  [ -n "$CODE" ] && break
  sleep 1
done
[ -n "$CODE" ] || { cat "$TMP/cancel.err"; fail "没有看到配对核对码"; }
kill -INT $CANCEL_PID
wait $CANCEL_PID 2>/dev/null || true
sleep 1
if manager phone approve "$CODE" OpenAI:rw >/dev/null 2>&1; then fail "取消后的配对请求仍然可以批准"; fi

step "J3 终端失去响应（心跳中断）后，请求自动作废"
echo "$PASSWORD" | HARMONIA_HOME="$TMP/cli-stall" "$TMP/harmonia" login "$SERVER" --email "$EMAIL" --password-stdin --name "e2e-stall" \
  >/dev/null 2>"$TMP/stall.err" &
STALL_PID=$!
CODE=""
for _ in $(seq 1 60); do
  CODE=$(grep -ao '核对码：[0-9A-HJKMNP-TV-Z-]*' "$TMP/stall.err" | sed 's/核对码：//' || true)
  [ -n "$CODE" ] && break
  sleep 1
done
[ -n "$CODE" ] || { cat "$TMP/stall.err"; fail "没有看到配对核对码"; }
kill -STOP $STALL_PID
sleep 42
if manager phone approve "$CODE" OpenAI:rw >/dev/null 2>&1; then fail "心跳中断后的配对请求仍然可以批准"; fi
kill -KILL $STALL_PID 2>/dev/null || true

step "J3 电脑登录并配对"
echo "$PASSWORD" | HARMONIA_HOME="$TMP/cli" "$TMP/harmonia" login "$SERVER" --email "$EMAIL" --password-stdin --name "e2e-laptop" \
  >"$TMP/login.out" 2>"$TMP/login.err" &
LOGIN_PID=$!
CODE=""
for _ in $(seq 1 60); do
  CODE=$(grep -ao '核对码：[0-9A-HJKMNP-TV-Z-]*' "$TMP/login.err" | sed 's/核对码：//' || true)
  [ -n "$CODE" ] && break
  sleep 1
done
[ -n "$CODE" ] || { cat "$TMP/login.err"; fail "没有看到配对核对码"; }
manager phone approve "$CODE" OpenAI:rw >/dev/null
wait $LOGIN_PID || { cat "$TMP/login.err"; fail "CLI 登录失败"; }
grep -q "可以访问 1 个环境" "$TMP/login.out" || fail "配对后环境数量不对"

step "J4 授权的环境默认启用，通过 exec 使用"
expect_eq "$(cli exec -- printenv OPENAI_API_KEY 2>/dev/null)" "sk-first 'quoted' \$(no)" "exec 注入"
expect_eq "$(bash -c ". '$TMP/cli/env.sh'; printf %s \"\$OPENAI_API_KEY\"")" "sk-first 'quoted' \$(no)" "env.sh 内容"

step "J4 实时推送：后台服务 3 秒内收到手机上的修改"
HARMONIA_HOME="$TMP/cli" "$TMP/harmonia" daemon &
DAEMON_PID=$!
sleep 3
manager phone var-set OpenAI OPENAI_API_KEY "sk-second" >/dev/null
START=$(date +%s)
until grep -q "sk-second" "$TMP/cli/env.sh"; do
  [ $(( $(date +%s) - START )) -le 5 ] || fail "推送后 5 秒内 env.sh 没有更新"
  sleep 0.2
done
echo "推送生效用时 $(( $(date +%s) - START )) 秒"

step "J5 电脑写入，手机可读"
cli var set OpenAI FROM_CLI "written-by-cli" >/dev/null
expect_eq "$(manager phone var-get OpenAI FROM_CLI)" "written-by-cli" "手机读取电脑写入的值"

step "J6 本地覆盖：只在本机生效，云端删除后失效"
cli override set OpenAI FROM_CLI "local-only" >/dev/null
expect_eq "$(cli exec -- printenv FROM_CLI 2>/dev/null)" "local-only" "本地覆盖生效"
expect_eq "$(manager phone var-get OpenAI FROM_CLI)" "written-by-cli" "云端值不受本地覆盖影响"
cli var rm OpenAI FROM_CLI >/dev/null
expect_eq "$(cli exec -- sh -c 'printf %s "${FROM_CLI-unset}"' 2>/dev/null)" "unset" "云端删除后覆盖失效"

step "J4 激活与顺序：手机和电脑两边修改，env.sh 随之变化"
wait_env() {
  START=$(date +%s)
  until [ "$(bash -c ". '$TMP/cli/env.sh'; printf %s \"\$OPENAI_API_KEY\"")" == "$1" ]; do
    [ $(( $(date +%s) - START )) -le 5 ] || fail "$2：5 秒内 env.sh 没有变为 [$1]"
    sleep 0.2
  done
}
manager phone var-set Other OPENAI_API_KEY "from-other" >/dev/null
manager phone grants e2e-laptop OpenAI:rw Other:ro >/dev/null
cli sync >/dev/null
wait_env "sk-second" "新授权的环境默认启用并排在最后"
manager phone activation e2e-laptop Other OpenAI >/dev/null
wait_env "from-other" "手机把 Other 移到最前"
manager phone activation e2e-laptop Other:off OpenAI >/dev/null
wait_env "sk-second" "手机停用 Other"
cli env activate Other >/dev/null
wait_env "from-other" "电脑重新启用 Other"
cli env order OpenAI >/dev/null
wait_env "sk-second" "电脑把 OpenAI 移到最前"
cli env list | grep -q "OPENAI_API_KEY：使用“OpenAI”中的值（同时出现在“Other”）" || fail "env list 没有显示同名变量来源"
expect_eq "$(manager phone devices | grep e2e-laptop | cut -f3)" "OpenAI:rw,Other:ro" "手机看到电脑上的顺序"
cli env deactivate Other >/dev/null
expect_eq "$(manager phone devices | grep e2e-laptop | cut -f3)" "OpenAI:rw,Other:ro:off" "手机看到电脑停用的环境"

step "J7 降为只读后写入被拒绝；未授权环境不可见"
manager phone grants e2e-laptop OpenAI:ro >/dev/null
cli sync >/dev/null
if cli var set OpenAI NEW "x" 2>"$TMP/ro.err"; then fail "只读设备不应能写入"; fi
grep -q "只读" "$TMP/ro.err" || fail "只读错误提示不清楚：$(cat "$TMP/ro.err")"
cli env list | grep -q Other && fail "未授权的环境不应可见"

step "J9 第二台管理设备加入，并能管理全部环境"
manager phone2 pair --server "$SERVER" --email "$EMAIL" --password "$PASSWORD" --name "第二台手机" \
  >"$TMP/pair2.out" 2>"$TMP/pair2.err" &
PAIR_PID=$!
CODE2=""
for _ in $(seq 1 60); do
  CODE2=$(grep -ao '核对码：[0-9A-HJKMNP-TV-Z-]*' "$TMP/pair2.err" | sed 's/核对码：//' || true)
  [ -n "$CODE2" ] && break
  sleep 1
done
[ -n "$CODE2" ] || { cat "$TMP/pair2.err"; fail "第二台手机没有拿到核对码"; }
manager phone approve "$CODE2" manager >/dev/null
wait $PAIR_PID || { cat "$TMP/pair2.err"; fail "第二台手机配对失败"; }
expect_eq "$(cat "$TMP/pair2.out")" "manager" "第二台手机的身份"
expect_eq "$(manager phone2 var-get OpenAI OPENAI_API_KEY)" "sk-second" "第二台手机读取已有环境"
manager phone2 env-create FromPhone2 >/dev/null
manager phone2 var-set FromPhone2 SHARED "from-phone-2" >/dev/null
expect_eq "$(manager phone var-get FromPhone2 SHARED)" "from-phone-2" "第一台手机读取第二台手机创建的环境"

step "J7 撤销：在线设备立即清除本机数据"
manager phone revoke e2e-laptop >/dev/null
START=$(date +%s)
until [ ! -f "$TMP/cli/keys.json" ]; do
  [ $(( $(date +%s) - START )) -le 5 ] || fail "撤销后 5 秒内本机数据没有清除"
  sleep 0.2
done
grep -q "OPENAI_API_KEY" "$TMP/cli/env.sh" && fail "撤销后 env.sh 仍有变量"
cli status | grep -q "还没有接入账号" || fail "撤销后状态不对"

step "J8 恢复：新手机用恢复码恢复，必须轮换；旧恢复码失效"
expect_eq "$(manager phone3 recover --server "$SERVER" --email "$EMAIL" --code "$RECOVERY" --name "恢复手机")" "rotation-required" "恢复后需要轮换"
NEWCODE=$(manager phone3 rotate)
expect_eq "$(manager phone3 var-get OpenAI OPENAI_API_KEY)" "sk-second" "恢复后能读取数据"

step "J8 恢复后移除旧手机：旧手机在移除前仍然有效，移除后失效"
expect_eq "$(manager phone var-get OpenAI OPENAI_API_KEY)" "sk-second" "恢复后旧手机仍可读取"
manager phone3 revoke 主手机 >/dev/null
manager phone3 revoke 第二台手机 >/dev/null
if manager phone sync >/dev/null 2>&1; then fail "移除后主手机应当失效"; fi
if manager phone2 sync >/dev/null 2>&1; then fail "移除后第二台手机应当失效"; fi
if manager phone4 recover --server "$SERVER" --email "$EMAIL" --code "$RECOVERY" >/dev/null 2>&1; then fail "旧恢复码应已失效"; fi
expect_eq "$(manager phone4 recover --server "$SERVER" --email "$EMAIL" --code "$NEWCODE")" "rotation-required" "新恢复码可用"

printf '\n\033[32m全部端到端流程通过。\033[0m\n'
