#!/usr/bin/env bash
# 端到端流程测试：本地 workerd 服务端 + 真实 harmonia CLI + 无界面管理设备（app/lib/core）。
# 覆盖：注册验证（含重新注册未初始化的账号）、首次初始化、匿名查询、电脑配对（扫码方式与配对码方式、取消等待、配对码输错）、
# exec、实时推送、写入、本地覆盖、权限变更、撤销、恢复与轮换、多管理设备、电脑管理登录（本机管理页面的接口）、
# 后台通知（本地推送中继，不连接 APNs、FCM）。账号没有密码。
set -euo pipefail

# shellcheck source=e2e/setup.sh
source "$(dirname "$0")/setup.sh"

step "J1 注册、验证邮箱、首次初始化（没有密码）"
expect_eq "$(manager phone lookup --server "$SERVER" --email "$EMAIL")" "not-registered" "注册前查询"
REG=$(manager phone register --server "$SERVER" --email "$EMAIL")
expect_eq "$(printf %s "$REG" | cut -f1)" "verification-required" "注册"
sleep 1
manager phone verify --server "$SERVER" --email "$EMAIL" --flow "$(printf %s "$REG" | cut -f2)" --code "$(mail_code verification)" >/dev/null
expect_eq "$(manager phone lookup --server "$SERVER" --email "$EMAIL")" "uninitialized" "验证后、初始化前查询"
# 已注册但未初始化的账号可以重新注册，按新注册处理（服务端已放宽重发间隔，见 docs/protocol.md 3.8）。
REG=$(manager phone register --server "$SERVER" --email "$EMAIL")
expect_eq "$(printf %s "$REG" | cut -f1)" "verification-required" "重新注册未初始化的账号"
sleep 1
manager phone verify --server "$SERVER" --email "$EMAIL" --flow "$(printf %s "$REG" | cut -f2)" --code "$(mail_code verification)" >/dev/null
RECOVERY=$(manager phone setup --name "主手机")
[[ "$RECOVERY" =~ ^[0-9A-HJKMNP-TV-Z]{4}(-[0-9A-HJKMNP-TV-Z]{1,4}){6}$ ]] || fail "恢复码格式：$RECOVERY"
expect_eq "$(manager other lookup --server "$SERVER" --email "$EMAIL")" "initialized" "初始化后查询"
DUP=$(manager other register --server "$SERVER" --email "$EMAIL" 2>&1 || true)
[[ "$DUP" == *"这个邮箱已经注册并完成了设置"* ]] || fail "已初始化的邮箱重新注册应当被拒绝，实际：$DUP"
expect_eq "$(manager phone push-register --relay "$RELAY" --token e2e-push-token)" "ok" "手机登记后台通知"

OPENAI_ENV_ID=$(manager phone env-create OpenAI)
OTHER_ENV_ID=$(manager phone env-create Other)
[ -n "$OPENAI_ENV_ID" ] && [ -n "$OTHER_ENV_ID" ] || fail "新建环境没有返回 ID"
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
grep -aq "type=pairing" "$TMP/relay.log" && fail "匿名配对请求不应发后台通知"
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
expect_push pairing "用配对码发起的配对请求"
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
ENV_LIST=$(cli env list)
expect_has "$ENV_LIST" "环境 ID" "env list 没有显示环境 ID 列"
expect_has "$ENV_LIST" "OpenAI[[:space:]]+$OPENAI_ENV_ID[[:space:]]" "env list 没有显示完整环境 ID"
expect_eq "$(cli exec --env "$OPENAI_ENV_ID" -- printenv OPENAI_API_KEY 2>/dev/null)" "sk-first 'quoted' \$(no)" "--env 使用完整环境 ID"
[ -e "$TMP/cli/env.sh" ] && fail "没有开启 Shell 集成时不应生成 env.sh"
if cli export >/dev/null 2>&1; then fail "export 不指明范围时不应输出"; fi
expect_eq "$(cli export --all --format json 2>/dev/null | grep -c OPENAI_API_KEY)" "1" "export --all 输出全部启用的变量"

step "开启 Shell 集成后才写出 env.sh"
mkdir -p "$TMP/home"
HOME="$TMP/home" cli shell install --yes --shell bash >/dev/null
expect_eq "$(bash -c ". '$TMP/cli/env.sh'; printf %s \"\$OPENAI_API_KEY\"")" "sk-first 'quoted' \$(no)" "env.sh 内容"

step "在手机上让电脑更新：后台服务不在线时给出下一步"
OFFLINE=$(manager phone cli-update e2e-laptop 2>&1 || true)
[[ "$OFFLINE" == *"后台服务现在没有连上服务器"* ]] || fail "后台服务没运行时应当提示不在线，实际：$OFFLINE"

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
cli var set --vault OpenAI FROM_CLI "first-write" >/dev/null
expect_eq "$(manager phone var-get OpenAI FROM_CLI)" "first-write" "显式指定变量库新增变量"
cli var set --vault openai FROM_CLI "written-by-cli" >/dev/null
expect_eq "$(manager phone var-get OpenAI FROM_CLI)" "written-by-cli" "手机读取电脑写入的值"

step "J5 变量备注：手机写入多行备注，电脑可见；电脑只改备注不动值"
manager phone var-set OpenAI NOTED "v1" $'第一行备注\n第二行' >/dev/null
expect_has "$(cli var list --env "$OPENAI_ENV_ID")" "NOTED .*第一行备注 …" "按环境 ID 列出变量时没有显示备注"
cli var set "$OPENAI_ENV_ID" NOTED "v2" >/dev/null
expect_eq "$(manager phone var-get OpenAI NOTED)" "v2" "通过环境 ID 修改已有变量的值"
cli var set "$OPENAI_ENV_ID" NOTED --note "电脑改的备注" >/dev/null
expect_eq "$(manager phone var-get OpenAI NOTED)" "v2" "只改备注时值不变"
expect_eq "$(manager phone var-note OpenAI NOTED)" "电脑改的备注" "手机读取电脑改的备注"
cli var rm "$OPENAI_ENV_ID" NOTED >/dev/null
expect_eq "$(manager phone var-get OpenAI NOTED)" "" "通过环境 ID 删除变量库里的原变量"

step "批量导入：一次请求写入，重跑跳过已写入的，逐条输出结果"
printf 'IMPORT_A=1\nIMPORT_B="two words"\n' >"$TMP/import.env"
cli import --vault OpenAI --file "$TMP/import.env" >"$TMP/import.out" || { cat "$TMP/import.out"; fail "导入失败"; }
grep -q "已写入 2 个" "$TMP/import.out" || fail "第一次导入应写入 2 个：$(cat "$TMP/import.out")"
expect_eq "$(manager phone var-get OpenAI IMPORT_B)" "two words" "手机读取导入的值"
expect_eq "$(cli import --vault OpenAI --file "$TMP/import.env" --json | grep -c '"unchanged"')" "2" "重跑时全部未变化"
printf '{"IMPORT_A":"1","IMPORT_C":"3"}' | cli import --vault OpenAI --file - >/dev/null || fail "从标准输入导入 JSON 失败"
expect_eq "$(manager phone var-get OpenAI IMPORT_C)" "3" "JSON 导入"
printf 'IMPORT_D=4\n没有等号\n' >"$TMP/bad.env"
if cli import --vault OpenAI --file "$TMP/bad.env" >/dev/null 2>&1; then fail "有无法识别的行时不应导入"; fi
expect_eq "$(manager phone var-get OpenAI IMPORT_D)" "" "解析失败时整份都不应写入"
RC=0; cli exec --env OpenAI:MISSING -- true 2>/dev/null || RC=$?
expect_eq "$RC" "125" "exec 自身出错时退出码为 125"

step "J6 本地覆盖：只在本机生效，云端删除后失效"
cli override set "$OPENAI_ENV_ID" FROM_CLI "local-only" >/dev/null
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
cli env activate "$OTHER_ENV_ID" >/dev/null
wait_env "from-other" "电脑重新启用 Other"
cli env order "$OPENAI_ENV_ID" >/dev/null
wait_env "sk-second" "电脑把 OpenAI 移到最前"
expect_has "$(cli env list)" "OPENAI_API_KEY  使用“OpenAI”中的值，同时出现在“Other”" "env list 没有显示同名变量来源"
expect_eq "$(manager phone devices | grep e2e-laptop | cut -f3)" "OpenAI:rw,Other:ro" "手机看到电脑上的顺序"
cli env deactivate "$OTHER_ENV_ID" >/dev/null
expect_eq "$(manager phone devices | grep e2e-laptop | cut -f3)" "OpenAI:rw,Other:ro:off" "手机看到电脑停用的环境"

step "exec --env：只用指定的环境，终端里其他环境的变量不传给命令"
manager phone var-set OpenAI ONLY_OPENAI "only-openai" >/dev/null
START=$(date +%s)
until grep -q "only-openai" "$TMP/cli/env.sh"; do
  [ $(( $(date +%s) - START )) -le 5 ] || fail "env.sh 没有收到 ONLY_OPENAI"
  sleep 0.2
done
expect_eq "$(cli exec --env Other --env OpenAI -- printenv OPENAI_API_KEY 2>/dev/null)" "from-other" "--env 可以使用已停用的环境，重复给出时先列出的优先"
# 模拟开启了 Shell 集成的终端：先加载 env.sh，再用 --env 只选 Other。
expect_eq "$(bash -c ". '$TMP/cli/env.sh'; export MINE=kept; HARMONIA_HOME='$TMP/cli' '$TMP/harmonia' exec --env Other -- sh -c 'printf \"%s %s\" \"\${ONLY_OPENAI-unset}\" \"\$MINE\"'" 2>/dev/null)" "unset kept" "--env 时不带上终端里其他环境的变量，保留用户自己的变量"
expect_eq "$(cli exec --env "$OTHER_ENV_ID,$OPENAI_ENV_ID:ONLY_OPENAI" -- sh -c 'printf "%s %s" "$OPENAI_API_KEY" "$ONLY_OPENAI"' 2>/dev/null)" "from-other only-openai" "--env 完整环境 ID 和 ID:变量名可以组合选择"
expect_eq "$(bash -c ". '$TMP/cli/env.sh'; HARMONIA_HOME='$TMP/cli' '$TMP/harmonia' exec --env '$OPENAI_ENV_ID:ONLY_OPENAI' -- sh -c 'printf \"%s %s\" \"\${OPENAI_API_KEY-unset}\" \"\$ONLY_OPENAI\"'" 2>/dev/null)" "unset only-openai" "按 ID:变量名筛选时，终端里同一环境的其他变量也不传给命令"
cli exec --env OpenAI:NOT_THERE -- true 2>/dev/null && fail "指定的变量不存在时不应运行命令"
expect_eq "$(cli exec --env other:OPENAI_API_KEY -- printenv OPENAI_API_KEY 2>/dev/null)" "from-other" "--env 的环境名不区分大小写"
# 终端里是旧值时，不加 --env 也以最新值为准（同名变量只传一份）。
expect_eq "$(bash -c "export OPENAI_API_KEY=stale; HARMONIA_HOME='$TMP/cli' '$TMP/harmonia' exec -- sh -c 'env | grep -c ^OPENAI_API_KEY=; printenv OPENAI_API_KEY'" 2>/dev/null | tr '\n' ' ')" "1 sk-second " "同名变量只传最新值"

step "两层结构：环境引用变量库，按勾选和改名展开，写回变量库里的原变量"
SHARED_VAULT_ID=$(manager phone vault-create Shared)
manager phone var-set Shared TOKEN "tok-1" >/dev/null
manager phone var-set Shared MODEL "gpt" >/dev/null
MIX_ENV_ID=$(manager phone env-define Mix Shared:pick:TOKEN=LLM_TOKEN OpenAI:all)
[ -n "$SHARED_VAULT_ID" ] && [ -n "$MIX_ENV_ID" ] || fail "新建变量库或环境没有返回 ID"
if manager phone env-define Dup OpenAI:all Other:all >/dev/null 2>&1; then fail "两个变量库都有 OPENAI_API_KEY 时不应能保存环境"; fi
manager phone env-define Dup OpenAI:all Other:all:OPENAI_API_KEY=OTHER_KEY >/dev/null || fail "给重名变量改名后应能保存"
manager phone env-delete Dup >/dev/null
manager phone grants e2e-laptop OpenAI:rw Other:ro Mix:rw >/dev/null
cli sync >/dev/null
expect_eq "$(cli exec --env Mix -- sh -c 'printf "%s %s %s" "$LLM_TOKEN" "${MODEL-unset}" "$OPENAI_API_KEY"' 2>/dev/null)" "tok-1 unset sk-second" "勾选并改名的变量、引用全部变量的变量库"
expect_has "$(cli var list --env Mix)" "LLM_TOKEN.*来自 Shared / TOKEN" "var list 没有显示变量来自哪个变量库"
cli var set Mix LLM_TOKEN "tok-2" --yes >/dev/null || fail "通过环境用新名字修改失败"
expect_eq "$(manager phone var-get Shared TOKEN)" "tok-2" "写回变量库里的原变量"
if cli var set "$SHARED_VAULT_ID" TOKEN "wrong-target" --yes 2>"$TMP/w.err"; then fail "变量库 ID 不应默认作为环境目标写入"; fi
expect_has "$(cat "$TMP/w.err")" "找不到环境" "变量库 ID 应按环境目标解析"
if cli var rm "$SHARED_VAULT_ID" TOKEN --yes 2>"$TMP/w.err"; then fail "变量库 ID 不应默认作为环境目标删除"; fi
expect_has "$(cat "$TMP/w.err")" "找不到环境" "删除时变量库 ID 应按环境目标解析"
expect_eq "$(manager phone var-get Shared TOKEN)" "tok-2" "拒绝变量库位置参数后原变量不变"
cli var set --vault "$SHARED_VAULT_ID" TOKEN --note "按库 ID 修改" --yes >/dev/null
expect_eq "$(manager phone var-note Mix LLM_TOKEN)" "按库 ID 修改" "显式变量库 ID 使用原名修改，环境里的新名字可读"
if cli var set Other OPENAI_API_KEY "x" --yes 2>"$TMP/w.err"; then fail "只读授权时不应能写入"; fi
grep -q "只读" "$TMP/w.err" || fail "只读的提示不清楚：$(cat "$TMP/w.err")"
if cli var set Mix BRAND_NEW "x" 2>"$TMP/w.err"; then fail "环境里没有的变量不应能通过环境新增"; fi
grep -q "可以新增变量的变量库：“OpenAI”" "$TMP/w.err" || fail "没有列出可以新增变量的变量库：$(cat "$TMP/w.err")"
if cli var set openai BRAND_NEW "x" 2>"$TMP/w.err"; then fail "环境和变量库同名时不应自动新增"; fi
expect_has "$(cat "$TMP/w.err")" "--vault" "新增失败时应提示显式指定变量库"
expect_eq "$(manager phone var-get OpenAI BRAND_NEW)" "" "同名环境新增失败后变量库没有新变量"
cli var set --vault OpenAI BRAND_NEW "x" >/dev/null
expect_eq "$(manager phone var-get OpenAI BRAND_NEW)" "x" "显式指定同名变量库新增"
cli var rm --vault OpenAI BRAND_NEW --yes >/dev/null
expect_eq "$(manager phone var-get OpenAI BRAND_NEW)" "" "显式指定变量库删除原变量"
step "手机批准：没有开启本机解密的环境在使用时请求批准；拒绝、仅这一次、保管进程、仅这个终端、lock、写入"
manager phone grants e2e-laptop OpenAI:rw Other:ro Mix:rw:nolocal >/dev/null
cli sync >/dev/null
expect_has "$(cli env list)" "需要手机批准" "env list 没有显示需要手机批准"
expect_has "$(cli var list --env Mix)" "LLM_TOKEN.*需要手机批准" "var list 应只列出变量名"
expect_eq "$(manager phone devices | grep e2e-laptop | cut -f3)" "OpenAI:rw,Other:ro:off,Mix:rw:nolocal" "手机看到关闭了本机解密的环境"
# 等电脑上打印出请求码（只读本地文件，不请求服务器）。电脑在请求创建后才打印，手机上的 approval-approve、
# approval-reject 按这个码查找请求，找不到就失败，由此核对两边的码一致。
approval_code() {
  local code=""
  for _ in $(seq 1 100); do
    code=$(grep -o "核对请求码 [0-9A-Z]*" "$TMP/ap.err" 2>/dev/null | cut -d' ' -f2) && [ -n "$code" ] && { echo "$code"; return; }
    sleep 0.1
  done
  fail "电脑上没有发起批准请求：$(cat "$TMP/ap.err")"
}
# 后台运行一条要批准的命令，结果写到 ap.out、ap.err。
ask() { : >"$TMP/ap.err"; "$@" >"$TMP/ap.out" 2>"$TMP/ap.err" & AP=$!; }
# 不需要批准时命令应在几秒内结束，期间手机上没有请求。
no_ask() {
  ask "$@"
  for _ in $(seq 1 50); do kill -0 $AP 2>/dev/null || break; sleep 0.1; done
  if kill -0 $AP 2>/dev/null; then kill $AP; fail "保管进程持有授权时不应再请求批准：$(cat "$TMP/ap.err")"; fi
  wait $AP || fail "命令失败：$(cat "$TMP/ap.err")"
}
PRINT_TOKEN=(sh -c 'printf %s "$LLM_TOKEN"')

ask cli exec --env Mix -- "${PRINT_TOKEN[@]}"
CODE=$(approval_code)
expect_push approval "新的批准请求"
manager phone approval-reject "$CODE" >/dev/null
rc=0; wait $AP || rc=$?
expect_eq "$rc" "125" "被拒绝时 exec 的退出码"
grep -q "手机上拒绝了这次请求" "$TMP/ap.err" || fail "没有说明被拒绝：$(cat "$TMP/ap.err")"

ask cli exec --env Mix -- "${PRINT_TOKEN[@]}"
manager phone approval-approve "$(approval_code)" once >/dev/null
wait $AP || fail "批准后命令没有运行：$(cat "$TMP/ap.err")"
expect_eq "$(cat "$TMP/ap.out")" "tok-2" "批准后拿到变量"
expect_eq "$(manager phone authorizations | grep -c e2e-laptop || true)" "0" "仅这一次不记录授权"

ask cli exec --env Mix -- "${PRINT_TOKEN[@]}"
manager phone approval-approve "$(approval_code)" all:30 >/dev/null
wait $AP || fail "批准后命令没有运行：$(cat "$TMP/ap.err")"
no_ask cli exec --env Mix -- "${PRINT_TOKEN[@]}"
expect_eq "$(cat "$TMP/ap.out")" "tok-2" "有效期内由保管进程提供"
expect_has "$(cli status)" "正在生效的授权" "status 没有列出正在生效的授权"
expect_has "$(manager phone authorizations)" "e2e-laptop	all" "手机上没有看到正在生效的授权"
# 变量在手机上被修改：授权随之结束，下次使用重新请求，拿到新值。
manager phone var-set Shared TOKEN "tok-3" >/dev/null
expect_eq "$(manager phone authorizations | grep -c e2e-laptop || true)" "0" "变量被修改后授权结束"
ask cli exec --env Mix -- "${PRINT_TOKEN[@]}"
manager phone approval-approve "$(approval_code)" terminal:30 >/dev/null
wait $AP || fail "批准后命令没有运行：$(cat "$TMP/ap.err")"
expect_eq "$(cat "$TMP/ap.out")" "tok-3" "重新批准后拿到新值"
no_ask cli exec --env Mix -- "${PRINT_TOKEN[@]}"
# 另一个终端会话（setsid）不能用“仅这个终端”的授权。电脑上的命令被强行结束（连接异常断开）后，
# 请求作废，手机上不能再处理。
ask perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' env HARMONIA_HOME="$TMP/cli" "$TMP/harmonia" exec --env Mix -- "${PRINT_TOKEN[@]}"
CODE=$(approval_code)
kill -9 $AP; wait $AP 2>/dev/null || true
sleep 1
if manager phone approval-reject "$CODE" >/dev/null 2>&1; then fail "电脑上结束等待后，请求仍然可以处理"; fi
expect_has "$(cli lock)" "已结束 1 项授权" "lock 没有结束授权"
expect_eq "$(manager phone authorizations | grep -c e2e-laptop || true)" "0" "lock 后手机上不再显示"
for _ in $(seq 1 20); do [ -S "$TMP/cli/keeper.sock" ] || break; sleep 0.1; done
[ -S "$TMP/cli/keeper.sock" ] && fail "lock 后保管进程应退出"
# 写入：经手机批准，由手机写入变量库里的原变量。
ask cli var set "$MIX_ENV_ID" LLM_TOKEN "tok-w" --yes
CODE=$(approval_code)
expect_has "$(manager phone approvals)" "write	LLM_TOKEN" "写入请求的内容不对"
manager phone approval-approve "$CODE" >/dev/null
wait $AP || fail "写入失败：$(cat "$TMP/ap.err")"
grep -q "已在手机上批准并写入" "$TMP/ap.out" || fail "写入后的提示不对：$(cat "$TMP/ap.out")"
expect_eq "$(manager phone var-get Shared TOKEN)" "tok-w" "手机写入变量库里的原变量"
manager phone grants e2e-laptop OpenAI:rw Other:ro >/dev/null
manager phone env-delete Mix >/dev/null
manager phone vault-delete Shared >/dev/null
# 入口每分钟最多 300 个请求（protocol.md 3.8，DEV_RELAXED_LIMITS 不跳过），这一步加上后面几步会超出，等计数清零。
sleep 61

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

step "自动更新开关：电脑和手机两边都能修改；后台服务在线时手机可以让电脑更新"
cli update auto on >/dev/null
expect_eq "$(manager phone devices | grep e2e-laptop | cut -f6)" "auto-update" "手机看到电脑打开的自动更新"
manager phone auto-update e2e-laptop off >/dev/null
[[ "$(cli update auto)" == *"未开启"* ]] || fail "电脑应当看到手机关闭的自动更新"
expect_eq "$(manager phone cli-update e2e-laptop)" "ok" "后台服务在线时手机可以让电脑更新"

step "J7 降为只读后写入被拒绝；未授权环境不可见"
manager phone grants e2e-laptop OpenAI:ro >/dev/null
cli sync >/dev/null
if cli var set OpenAI NEW "x" 2>"$TMP/ro.err"; then fail "只读设备不应能写入"; fi
grep -q "只读" "$TMP/ro.err" || fail "只读错误提示不清楚：$(cat "$TMP/ro.err")"
expect_eq "$(cli env list | grep -c Other || true)" "0" "未授权的环境不应可见"

step "J9 第二台管理设备用配对码加入，并能管理全部环境"
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

step "M13 电脑管理登录：通过本机管理页面的接口登录、解锁、新建变量库和环境、批量导入、复制和退出"
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
NEWVAULT=$(mapi /api/vaults/create '{"name":"FromComputer"}' | field id)
[ -n "$NEWVAULT" ] || fail "电脑没能新建变量库"
expect_eq "$(mapi /api/envs/list | grep -c '"name":"FromComputer"' || true)" "0" "新建变量库不应同时建环境"
NEWENV=$(mapi /api/envs/create '{"name":"FromComputer","refs":[{"vaultId":"'$NEWVAULT'","scope":"all"}]}' | field id)
[ -n "$NEWENV" ] || fail "电脑没能新建引用新变量库的环境"
B_ENV='{"env":"'$NEWENV'"}'
B_VAULT='{"vault":"'$NEWVAULT'"}'
IMPORT='{"vault":"'$NEWVAULT'","text":"# 注释\nA=1\nB=\"two words\"\nexport C='"'"'x y'"'"'\n1BAD=x\n","names":["A","B","C"]}'
PREVIEW=$(mapi /api/import/preview "$IMPORT")
expect_eq "$(printf %s "$PREVIEW" | grep -o '"status":"new"' | wc -l | tr -d ' ')" "3" "导入对比：三个新增"
printf %s "$PREVIEW" | grep -q '"line":5' || fail "导入对比应当指出第 5 行不合法：$PREVIEW"
mapi /api/import/apply "$IMPORT" | grep -q '"error"' && fail "批量导入有失败项"
expect_eq "$(manager phone var-get FromComputer B)" "two words" "手机读取电脑新建环境里导入的变量"
expect_eq "$(manager phone2 var-get FromComputer C)" "x y" "第二台手机同样能读取"
expect_eq "$(mapi /api/import/preview "$IMPORT" | grep -o '"status":"same"' | wc -l | tr -d ' ')" "3" "再次对比：三个不变"
OTHER=$(mapi /api/vaults/list | grep -o '"id":"[^"]*","name":"Other"' | cut -d'"' -f4)
mapi /api/copy/apply "{\"from\":\"$NEWVAULT\",\"to\":\"$OTHER\",\"names\":[\"A\"]}" | grep -q '"error"' && fail "跨变量库复制失败"
expect_eq "$(manager phone var-get Other A)" "1" "手机读取复制到其他变量库的变量"
B_REFS='{"name":"Combo","refs":[{"vaultId":"'$NEWVAULT'","scope":"pick","items":[{"name":"C","as":"CC"}]},{"vaultId":"'$OTHER'","scope":"all"}]}'
mapi /api/envs/preview "$B_REFS" | grep -q '"duplicates":\[\]' || fail "预览不应有重名：$(mapi /api/envs/preview "$B_REFS")"
COMBO=$(mapi /api/envs/create "$B_REFS" | field id)
[ -n "$COMBO" ] || fail "电脑没能新建引用两个变量库的环境"
mapi /api/envs/get '{"env":"'$COMBO'"}' | grep -q '"name":"CC","vaultId":"'$NEWVAULT'","source":"C"' || fail "环境里应有改名后的 CC"
expect_eq "$(manager phone var-get Combo CC)" "x y" "手机读取电脑新建的环境里改名后的变量"
B_DUP='{"name":"Dup","refs":[{"vaultId":"'$OTHER'","scope":"all"},{"vaultId":"'$NEWVAULT'","scope":"pick","items":[{"name":"A"}]}]}'
mapi /api/envs/create "$B_DUP" | grep -q '"error"' || fail "重名时不应能新建环境"
mapi /api/envs/delete '{"env":"'$COMBO'"}' >/dev/null
mapi /api/vars/delete "{\"vault\":\"$NEWVAULT\",\"names\":[\"A\",\"B\"]}" | grep -q '"error"' && fail "多选删除失败"
expect_eq "$(mapi /api/vars/list "$B_VAULT" | grep -o '"name":"[^"]*"' | tr -d '\n')" '"name":"C"' "删除后只剩一个变量"
manager phone var-set FromComputer FROM_PHONE "pushed" >/dev/null
START=$(date +%s)
until mapi /api/vars/list "$B_VAULT" | grep -q FROM_PHONE; do
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
mapi /api/vaults/delete "$B_VAULT" >/dev/null
if manager phone var-get FromComputer C >/dev/null 2>&1; then fail "电脑删除变量库和环境后手机不应还能读取"; fi
expect_eq "$(mapi /api/logout "$B_PASS" | field phase)" "login" "退出管理登录"
[ -f "$TMP/cli/manager.json" ] && fail "退出管理登录后应当删除本机的管理密钥"
[[ "$(manager phone devices)" == *"e2e 管理"* ]] && fail "退出管理登录后手机上不应还有这台电脑的管理身份"
cli sync >/dev/null || fail "退出管理登录不应影响日常登录"
kill -INT $MGR_PID; wait $MGR_PID 2>/dev/null || true; MGR_PID=""

step "关闭 Shell 集成时删除变量文件，后台服务不再写出"
HOME="$TMP/home" cli shell uninstall >/dev/null
[ -e "$TMP/cli/env.sh" ] || [ -e "$TMP/cli/shell.sh" ] && fail "关闭 Shell 集成后 env.sh、shell.sh 应当删除"
cli sync >/dev/null
[ -e "$TMP/cli/env.sh" ] && fail "关闭 Shell 集成后同步不应再写出 env.sh"

step "J7 撤销：在线设备立即清除本机数据"
manager phone revoke e2e-laptop >/dev/null
START=$(date +%s)
until [ ! -f "$TMP/cli/keys.json" ]; do
  [ $(( $(date +%s) - START )) -le 5 ] || fail "撤销后 5 秒内本机数据没有清除"
  sleep 0.2
done
[ -e "$TMP/cli/env.sh" ] && fail "撤销后 env.sh 应当不存在"
expect_has "$(cli status)" "还没有接入账号" "撤销后状态不对"

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
