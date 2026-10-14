#!/usr/bin/env bash
# 端到端流程测试：本地 workerd 服务端 + 真实 harmonia CLI + 无界面管理设备（app/lib/core）。
# 覆盖：注册验证（含重新注册未初始化的账号）、首次初始化、匿名查询、电脑配对（扫码方式与配对码方式、取消等待、配对码输错）、
# exec、实时推送、写入、本地覆盖、权限变更、撤销、恢复与轮换、多管理设备、电脑管理登录（本机管理页面的接口）。账号没有密码。
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP="$ROOT/e2e/.tmp"
PORT=8799
SERVER="http://localhost:$PORT"
EMAIL="e2e-$RANDOM@example.com"

rm -rf "$TMP" && mkdir -p "$TMP"
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
fail() { printf '\033[31m失败：%s\033[0m\n' "$*"; exit 1; }
expect_eq() { [ "$1" == "$2" ] || fail "$3：期望 [$2]，实际 [$1]"; }

cleanup() {
  [ -n "${DAEMON_PID:-}" ] && kill "$DAEMON_PID" 2>/dev/null || true
  [ -n "${MGR_PID:-}" ] && kill "$MGR_PID" 2>/dev/null || true
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

step "J1 注册、验证邮箱、首次初始化（没有密码）"
expect_eq "$(manager phone lookup --server "$SERVER" --email "$EMAIL")" "not-registered" "注册前查询"
REG=$(manager phone register --server "$SERVER" --email "$EMAIL")
expect_eq "$(printf %s "$REG" | cut -f1)" "verification-required" "注册"
sleep 1
manager phone verify --server "$SERVER" --email "$EMAIL" --flow "$(printf %s "$REG" | cut -f2)" --code "$(mail_code verification)" >/dev/null
expect_eq "$(manager phone lookup --server "$SERVER" --email "$EMAIL")" "uninitialized" "验证后、初始化前查询"
# 已注册但未初始化的账号可以重新注册，按新注册处理（同一网络 60 秒内只能再发一次验证码）。
sleep 61
REG=$(manager phone register --server "$SERVER" --email "$EMAIL")
expect_eq "$(printf %s "$REG" | cut -f1)" "verification-required" "重新注册未初始化的账号"
sleep 1
manager phone verify --server "$SERVER" --email "$EMAIL" --flow "$(printf %s "$REG" | cut -f2)" --code "$(mail_code verification)" >/dev/null
RECOVERY=$(manager phone setup --name "主手机")
[[ "$RECOVERY" =~ ^[0-9A-HJKMNP-TV-Z]{4}(-[0-9A-HJKMNP-TV-Z]{1,4}){6}$ ]] || fail "恢复码格式：$RECOVERY"
expect_eq "$(manager other lookup --server "$SERVER" --email "$EMAIL")" "initialized" "初始化后查询"
DUP=$(manager other register --server "$SERVER" --email "$EMAIL" 2>&1 || true)
[[ "$DUP" == *"这个邮箱已经注册并完成了设置"* ]] || fail "已初始化的邮箱重新注册应当被拒绝，实际：$DUP"
manager phone env-create OpenAI >/dev/null
manager phone env-create Other >/dev/null
manager phone var-set OpenAI OPENAI_API_KEY "sk-first 'quoted' \$(no)" >/dev/null

step "J3 终端取消等待后，请求立即作废"
HARMONIA_HOME="$TMP/cli-cancel" "$TMP/harmonia" login "$SERVER" --email "$EMAIL" --name "e2e-cancel" \
  </dev/null >/dev/null 2>"$TMP/cancel.err" &
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

step "J3 配对码输错：终端给出可操作的提示，不发起请求"
if HARMONIA_HOME="$TMP/cli-wrong" "$TMP/harmonia" login "$SERVER" --email "$EMAIL" --code "ZZZZ-ZZZZ" --name "e2e-wrong" \
  </dev/null >/dev/null 2>"$TMP/wrong.err"; then fail "错误的配对码不应能发起配对"; fi
grep -q "配对码不对或已过期" "$TMP/wrong.err" || fail "配对码错误的提示不对：$(cat "$TMP/wrong.err")"
UNKNOWN=$(HARMONIA_HOME="$TMP/cli-wrong" "$TMP/harmonia" login "$SERVER" --email "nobody-$RANDOM@example.com" --code "" </dev/null 2>&1 || true)
[[ "$UNKNOWN" == *"这个邮箱还没有注册"* ]] || fail "未注册的邮箱提示不对：$UNKNOWN"

step "J3 用配对码发起后终端失去响应（心跳中断），请求自动作废"
PCODE=$(manager phone pairing-code)
HARMONIA_HOME="$TMP/cli-stall" "$TMP/harmonia" login "$SERVER" --email "$EMAIL" --code "$PCODE" --name "e2e-stall" \
  </dev/null >/dev/null 2>"$TMP/stall.err" &
STALL_PID=$!
CODE=""
for _ in $(seq 1 60); do
  CODE=$(grep -ao '核对码：[0-9A-HJKMNP-TV-Z-]*' "$TMP/stall.err" | sed 's/核对码：//' || true)
  [ -n "$CODE" ] && break
  sleep 1
done
[ -n "$CODE" ] || { cat "$TMP/stall.err"; fail "没有看到配对核对码"; }
grep -q "已用配对码发起请求" "$TMP/stall.err" || fail "用配对码发起时终端应当提示管理设备会弹出批准页"
expect_eq "$(manager phone pending | grep e2e-stall | cut -f2)" "authorized" "用配对码发起的请求进入待批准列表"
if HARMONIA_HOME="$TMP/cli-reuse" "$TMP/harmonia" login "$SERVER" --email "$EMAIL" --code "$PCODE" --name "e2e-reuse" \
  </dev/null >/dev/null 2>&1; then fail "配对码只能用一次"; fi
kill -STOP $STALL_PID
sleep 42
if manager phone approve "$CODE" OpenAI:rw >/dev/null 2>&1; then fail "心跳中断后的配对请求仍然可以批准"; fi
kill -KILL $STALL_PID 2>/dev/null || true

step "J3 电脑不带配对码发起（扫码方式），手输核对码批准"
HARMONIA_HOME="$TMP/cli" "$TMP/harmonia" login "$SERVER" --email "$EMAIL" --name "e2e-laptop" \
  </dev/null >"$TMP/login.out" 2>"$TMP/login.err" &
LOGIN_PID=$!
CODE=""
for _ in $(seq 1 60); do
  CODE=$(grep -ao '核对码：[0-9A-HJKMNP-TV-Z-]*' "$TMP/login.err" | sed 's/核对码：//' || true)
  [ -n "$CODE" ] && break
  sleep 1
done
[ -n "$CODE" ] || { cat "$TMP/login.err"; fail "没有看到配对核对码"; }
grep -q "5 分钟内" "$TMP/login.err" || fail "终端应当提示请求 5 分钟内有效"
expect_eq "$(manager phone pending | grep e2e-laptop | cut -f2)" "anonymous" "不带配对码的请求是匿名请求"
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

step "J5 变量备注：手机写入多行备注，电脑可见；电脑只改备注不动值"
manager phone var-set OpenAI NOTED "v1" $'第一行备注\n第二行' >/dev/null
cli var list --env OpenAI | grep -q "NOTED .*第一行备注 …" || fail "电脑的变量列表没有显示备注"
cli var set OpenAI NOTED --note "电脑改的备注" >/dev/null
expect_eq "$(manager phone var-get OpenAI NOTED)" "v1" "只改备注时值不变"
expect_eq "$(manager phone var-note OpenAI NOTED)" "电脑改的备注" "手机读取电脑改的备注"
cli var rm OpenAI NOTED >/dev/null

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
cli env list | grep -q "OPENAI_API_KEY  使用“OpenAI”中的值，同时出现在“Other”" || fail "env list 没有显示同名变量来源"
expect_eq "$(manager phone devices | grep e2e-laptop | cut -f3)" "OpenAI:rw,Other:ro" "手机看到电脑上的顺序"
cli env deactivate Other >/dev/null
expect_eq "$(manager phone devices | grep e2e-laptop | cut -f3)" "OpenAI:rw,Other:ro:off" "手机看到电脑停用的环境"

step "exec --env：只用指定的环境，终端里其他环境的变量不传给命令"
# 本地测试的请求都来自同一个网络，设备登录挑战每分钟最多 30 次：先等过这一分钟。
sleep 61
manager phone var-set OpenAI ONLY_OPENAI "only-openai" >/dev/null
START=$(date +%s)
until grep -q "only-openai" "$TMP/cli/env.sh"; do
  [ $(( $(date +%s) - START )) -le 5 ] || fail "env.sh 没有收到 ONLY_OPENAI"
  sleep 0.2
done
expect_eq "$(cli exec --env Other --env OpenAI -- printenv OPENAI_API_KEY 2>/dev/null)" "from-other" "--env 可以使用已停用的环境，重复给出时先列出的优先"
# 模拟开启了 Shell 集成的终端：先加载 env.sh，再用 --env 只选 Other。
expect_eq "$(bash -c ". '$TMP/cli/env.sh'; export MINE=kept; HARMONIA_HOME='$TMP/cli' '$TMP/harmonia' exec --env Other -- sh -c 'printf \"%s %s\" \"\${ONLY_OPENAI-unset}\" \"\$MINE\"'" 2>/dev/null)" "unset kept" "--env 时不带上终端里其他环境的变量，保留用户自己的变量"
expect_eq "$(cli exec --env Other,OpenAI:ONLY_OPENAI -- sh -c 'printf "%s %s" "$OPENAI_API_KEY" "$ONLY_OPENAI"' 2>/dev/null)" "from-other only-openai" "--env 环境:变量名 只取这一个变量"
expect_eq "$(bash -c ". '$TMP/cli/env.sh'; HARMONIA_HOME='$TMP/cli' '$TMP/harmonia' exec --env OpenAI:ONLY_OPENAI -- sh -c 'printf \"%s %s\" \"\${OPENAI_API_KEY-unset}\" \"\$ONLY_OPENAI\"'" 2>/dev/null)" "unset only-openai" "只取一个变量时，终端里同一环境的其他变量也不传给命令"
cli exec --env OpenAI:NOT_THERE -- true 2>/dev/null && fail "指定的变量不存在时不应运行命令"
OTHER_ID=$(cli env list | awk '$2 == "Other" { print $NF }')
[ -n "$OTHER_ID" ] || fail "env list 没有显示环境 ID"
expect_eq "$(cli exec --env "$OTHER_ID:OPENAI_API_KEY" -- printenv OPENAI_API_KEY 2>/dev/null)" "from-other" "--env 可以用环境 ID"
# 终端里是旧值时，不加 --env 也以最新值为准（同名变量只传一份）。
expect_eq "$(bash -c "export OPENAI_API_KEY=stale; HARMONIA_HOME='$TMP/cli' '$TMP/harmonia' exec -- sh -c 'env | grep -c ^OPENAI_API_KEY=; printenv OPENAI_API_KEY'" 2>/dev/null | tr '\n' ' ')" "1 sk-second " "同名变量只传最新值"

step "手机看到各台设备的版本"
cli sync >/dev/null
DEVICES=$(manager phone devices)
expect_eq "$(printf '%s\n' "$DEVICES" | grep e2e-laptop | cut -f5)" "dev" "手机看到电脑的版本"
expect_eq "$(printf '%s\n' "$DEVICES" | grep 主手机 | cut -f5)" "0.1.0" "手机看到自己的版本"

step "“写入系统变量”开关：手机修改后随同步下发到电脑"
manager phone system-vars e2e-laptop on >/dev/null
expect_eq "$(manager phone devices | grep e2e-laptop | cut -f4)" "system-vars" "手机看到开关已打开"
cli sync >/dev/null
grep -q '"systemVars": true' "$TMP/cli/cache.json" || fail "电脑没有收到写入系统变量开关"
manager phone system-vars e2e-laptop off >/dev/null
cli sync >/dev/null
grep -q '"systemVars": false' "$TMP/cli/cache.json" || fail "电脑没有收到关闭后的开关"

step "J7 降为只读后写入被拒绝；未授权环境不可见"
manager phone grants e2e-laptop OpenAI:ro >/dev/null
cli sync >/dev/null
if cli var set OpenAI NEW "x" 2>"$TMP/ro.err"; then fail "只读设备不应能写入"; fi
grep -q "只读" "$TMP/ro.err" || fail "只读错误提示不清楚：$(cat "$TMP/ro.err")"
cli env list | grep -q Other && fail "未授权的环境不应可见"

step "J9 第二台管理设备用配对码加入，并能管理全部环境"
# 本地测试的请求都来自同一个网络，设备登录挑战每分钟最多 30 次：先等过这一分钟。
sleep 61
PCODE2=$(manager phone pairing-code)
[ -n "$PCODE2" ] || fail "没有生成配对码"
manager phone2 pair --server "$SERVER" --email "$EMAIL" --code "$PCODE2" --name "第二台手机" \
  >"$TMP/pair2.out" 2>"$TMP/pair2.err" &
PAIR_PID=$!
CODE2=""
for _ in $(seq 1 60); do
  CODE2=$(grep -ao '核对码：[0-9A-HJKMNP-TV-Z-]*' "$TMP/pair2.err" | sed 's/核对码：//' || true)
  [ -n "$CODE2" ] && break
  sleep 1
done
[ -n "$CODE2" ] || { cat "$TMP/pair2.err"; fail "第二台手机没有拿到核对码"; }
expect_eq "$(manager phone pending | grep 第二台手机 | cut -f2)" "authorized" "用配对码发起的手机进入待批准列表"
manager phone approve "$CODE2" manager >/dev/null
wait $PAIR_PID || { cat "$TMP/pair2.err"; fail "第二台手机配对失败"; }
expect_eq "$(cat "$TMP/pair2.out")" "manager" "第二台手机的身份"
expect_eq "$(manager phone2 var-get OpenAI OPENAI_API_KEY)" "sk-second" "第二台手机读取已有环境"
manager phone2 env-create FromPhone2 >/dev/null
manager phone2 var-set FromPhone2 SHARED "from-phone-2" >/dev/null
expect_eq "$(manager phone var-get FromPhone2 SHARED)" "from-phone-2" "第一台手机读取第二台手机创建的环境"

step "M13 电脑管理登录：通过本机管理页面的接口登录、解锁、新建环境、批量导入、复制和退出"
# 设备登录挑战每分钟最多 30 次：先等过这一分钟。
sleep 61
MPORT=8798
MURL="http://127.0.0.1:$MPORT"
MPASS="E2e-$RANDOM-Mgr"
# 直接启动程序而不经过 cli 函数，这样 MGR_PID 就是它本身，结束时能关掉。
HARMONIA_HOME="$TMP/cli" "$TMP/harmonia" manager --no-open --port $MPORT >"$TMP/mgr.out" 2>&1 &
MGR_PID=$!
for _ in $(seq 1 50); do grep -q "管理页面" "$TMP/mgr.out" 2>/dev/null && break; sleep 0.2; done
ACODE=$(grep -ao '#[A-Za-z0-9_-]*' "$TMP/mgr.out" | head -1 | cut -c2-)
[ -n "$ACODE" ] || { cat "$TMP/mgr.out"; fail "管理页面没有启动"; }
EMPTY='{}'
field() { grep -o "\"$1\":\"[^\"]*\"" | head -1 | cut -d'"' -f4; }
expect_eq "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: evil.example' "$MURL/")" "403" "Host 不是本机地址时拒绝"
expect_eq "$(curl -s -o /dev/null -w '%{http_code}' "$MURL/api/state")" "401" "没有令牌时拒绝"
# 请求内容先放进变量：macOS 自带的 bash 3.2 会把写在 "$(...)" 里的带转义引号的 JSON 拆开。
B_CODE='{"code":"'$ACODE'"}'
B_LOGIN='{"deviceName":"e2e 管理","passphrase":"'$MPASS'"}'
B_PASS='{"passphrase":"'$MPASS'"}'
MTOKEN=$(curl -s -X POST -H 'Content-Type: application/json' -d "$B_CODE" "$MURL/api/session" | field token)
[ -n "$MTOKEN" ] || fail "访问码没有换到令牌"
expect_eq "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d "$B_CODE" "$MURL/api/session")" "403" "访问码只能用一次"
mapi() { curl -s -X POST -H 'Content-Type: application/json' -H "Authorization: Bearer $MTOKEN" -d "${2:-$EMPTY}" "$MURL$1"; }
mphase() { mapi /api/ping '{"active":true}' | field phase; }
expect_eq "$(mphase)" "login" "还没有管理登录"
mapi /api/login '{"deviceName":"e2e 管理","passphrase":"password1"}' | grep -q "太常见" || fail "常见口令应当被拒绝"
expect_eq "$(mapi /api/login "$B_LOGIN" | field phase)" "pairing" "发起管理登录"
MCODE=$(mapi /api/ping | field code)
[ -n "$MCODE" ] || fail "管理登录没有给出核对码"
manager phone approve "$MCODE" manager >/dev/null
for _ in $(seq 1 30); do [ "$(mphase)" == "unlocked" ] && break; sleep 0.5; done
expect_eq "$(mphase)" "unlocked" "批准后进入管理页面"
[ -f "$TMP/cli/manager.json" ] || fail "没有保存管理身份"
grep -q "signSeed\|boxSeed" "$TMP/cli/manager.json" && fail "管理身份的密钥不应以明文保存"
[ -f "$TMP/cli/keys.json" ] || fail "管理登录不应影响日常登录"
ENVS=$(mapi /api/envs/list)
for e in OpenAI Other FromPhone2; do printf %s "$ENVS" | grep -q "\"name\":\"$e\"" || fail "管理页面看不到环境 $e：$ENVS"; done
NEWENV=$(mapi /api/envs/create '{"name":"FromComputer"}' | field id)
[ -n "$NEWENV" ] || fail "电脑没能新建环境"
B_ENV='{"env":"'$NEWENV'"}'
IMPORT='{"env":"'$NEWENV'","text":"# 注释\nA=1\nB=\"two words\"\nexport C='"'"'x y'"'"'\n1BAD=x\n","names":["A","B","C"]}'
PREVIEW=$(mapi /api/import/preview "$IMPORT")
expect_eq "$(printf %s "$PREVIEW" | grep -o '"status":"new"' | wc -l | tr -d ' ')" "3" "导入对比：三个新增"
printf %s "$PREVIEW" | grep -q '"line":5' || fail "导入对比应当指出第 5 行不合法：$PREVIEW"
mapi /api/import/apply "$IMPORT" | grep -q '"error"' && fail "批量导入有失败项"
expect_eq "$(manager phone var-get FromComputer B)" "two words" "手机读取电脑新建环境里导入的变量"
expect_eq "$(manager phone2 var-get FromComputer C)" "x y" "第二台手机同样能读取"
expect_eq "$(mapi /api/import/preview "$IMPORT" | grep -o '"status":"same"' | wc -l | tr -d ' ')" "3" "再次对比：三个不变"
OTHER=$(printf %s "$ENVS" | grep -o '"id":"[^"]*","name":"Other"' | cut -d'"' -f4)
mapi /api/copy/apply "{\"from\":\"$NEWENV\",\"to\":\"$OTHER\",\"names\":[\"A\"]}" | grep -q '"error"' && fail "跨环境复制失败"
expect_eq "$(manager phone var-get Other A)" "1" "手机读取复制到其他环境的变量"
mapi /api/vars/delete "{\"env\":\"$NEWENV\",\"names\":[\"A\",\"B\"]}" | grep -q '"error"' && fail "多选删除失败"
expect_eq "$(mapi /api/vars/list "$B_ENV" | grep -o '"name":"[^"]*"' | tr -d '\n')" '"name":"C"' "删除后只剩一个变量"
manager phone var-set FromComputer FROM_PHONE "pushed" >/dev/null
START=$(date +%s)
until mapi /api/vars/list "$B_ENV" | grep -q FROM_PHONE; do
  [ $(( $(date +%s) - START )) -le 5 ] || fail "手机上的修改 5 秒内没有出现在管理页面"
  sleep 0.2
done
expect_eq "$(mapi /api/lock | field phase)" "locked" "手动锁定"
expect_eq "$(mapi /api/envs/list | field error)" "locked" "锁定后不能读取"
expect_eq "$(mapi /api/unlock '{"passphrase":"Wrong-pass-1"}' | field error)" "wrong_passphrase" "口令不对"
expect_eq "$(mapi /api/unlock "$B_PASS" | field phase)" "unlocked" "用口令解锁"
[[ "$(cli manager status)" == *已登录* ]] || fail "manager status 应当显示已登录"
[[ "$(cli status)" == *管理登录*已登录* ]] || fail "status 应当显示管理登录"
[[ "$(manager phone devices)" == *"e2e 管理"* ]] || fail "手机的设备列表里应当有电脑的管理身份"
mapi /api/envs/delete "$B_ENV" >/dev/null
if manager phone var-get FromComputer C >/dev/null 2>&1; then fail "电脑删除环境后手机不应还能读取"; fi
expect_eq "$(mapi /api/logout "$B_PASS" | field phase)" "login" "退出管理登录"
[ -f "$TMP/cli/manager.json" ] && fail "退出管理登录后应当删除本机的管理密钥"
[[ "$(manager phone devices)" == *"e2e 管理"* ]] && fail "退出管理登录后手机上不应还有这台电脑的管理身份"
cli sync >/dev/null || fail "退出管理登录不应影响日常登录"
kill -INT $MGR_PID; wait $MGR_PID 2>/dev/null || true; MGR_PID=""

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
