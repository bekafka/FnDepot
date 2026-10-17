#!/bin/bash
# ==============================================================================
# Motrix fpk 验收阶梯（在飞牛设备上以 root 跑；应用必须已装好）
#   bash motrix-accept.sh [阶段]
# 阶段：endpoints | auth | e2e | lifecycle | all
# ==============================================================================
set -u
APPNAME=Motrix
PKGVAR=/vol1/@appdata/$APPNAME
APPDEST=/vol1/@appcenter/$APPNAME
SAVE=/vol1/@appshare/$APPNAME/downloads
PORT=$(sed -n 's/^MOTRIX_PORT=//p' "$PKGVAR/config.env" | tail -1)
PORT=${PORT:-26800}
STAGE="${1:-all}"
LOG_FILE="$PKGVAR/info.log"
PASS=0; FAIL=0

ok()   { echo "  [PASS] $*"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
head2(){ echo; echo "── $* ──"; }

token() { cat "$PKGVAR/data/operator-token" 2>/dev/null; }

stage_status() {
  head2 "阶段 1：应用状态"
  st=$(appcenter-cli status "$APPNAME" 2>/dev/null)
  [ "$st" = "running" ] && ok "appcenter status = running" || bad "status = $st"
}

stage_endpoints() {
  head2 "阶段 2：端点"
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/healthz")
  [ "$code" = "200" ] && ok "/healthz = 200" || bad "/healthz = $code"
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/")
  [ "$code" = "200" ] && ok "首页 = 200" || bad "首页 = $code"
  asset=$(curl -s "http://127.0.0.1:$PORT/" | grep -o '/assets/[A-Za-z0-9._-]*\.js' | head -1)
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT$asset")
  [ "$code" = "200" ] && ok "静态资源 $asset = 200" || bad "静态资源 $asset = $code"
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://192.168.2.22:$PORT/healthz")
  [ "$code" = "200" ] && ok "局域网 IP 访问 = 200" || bad "局域网 IP 访问 = $code"
}

auth_mode() { cat "$APPDEST/AUTH_MODE" 2>/dev/null || echo token; }

stage_auth() {
  local mode; mode="$(auth_mode)"
  if [ "$mode" = "open" ]; then
    head2 "阶段 3：鉴权（已关闭口令登录）"
    status=$(curl -s "http://127.0.0.1:$PORT/rpc/auth/status")
    verdict=$(printf '%s' "$status" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(("authed" if d.get("authed") else "locked"), d.get("mode"))' 2>/dev/null)
    [ "$verdict" = "authed unrestricted" ] && ok "/rpc/auth/status = authed/unrestricted（无解锁页）" || bad "auth/status = $status"
    code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/diagnostics")
    [ "$code" = "200" ] && ok "无凭据直接访问 /api/diagnostics = 200（按设计开放）" || bad "无凭据 /api/diagnostics = $code"
    if grep -q "Unlock" <<<"$(curl -s "http://127.0.0.1:$PORT/")"; then
      bad "首页里仍有解锁页文案"
    else
      ok "首页不再要求解锁"
    fi
  else
    head2 "阶段 3：鉴权（口令模式）"
    code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/diagnostics")
    [ "$code" = "401" ] && ok "无 token 访问 /api/diagnostics = 401" || bad "无 token = $code（应为 401）"
    T="$(token)"
    code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $T" "http://127.0.0.1:$PORT/api/diagnostics")
    [ "$code" = "200" ] && ok "带 token 访问 /api/diagnostics = 200" || bad "带 token = $code"
    perm=$(stat -c '%a' "$PKGVAR/data/operator-token" 2>/dev/null)
    [ "$perm" = "600" ] && ok "口令文件权限 = 0600" || bad "口令文件权限 = $perm"
  fi
}

stage_e2e() {
  head2 "阶段 4：端到端下载（数据落到 data-share）"
  WORK=/tmp/motrix-accept; rm -rf "$WORK"; mkdir -p "$WORK"
  NAME="accept-$(date +%s).bin"        # 每次唯一，避免撞上上一轮的残留文件
  head -c 3145728 /dev/urandom > "$WORK/$NAME"
  SHA=$(sha256sum "$WORK/$NAME" | awk '{print $1}')
  ( cd "$WORK" && nohup python3 -m http.server 8897 --bind 127.0.0.1 > "$WORK/http.log" 2>&1 & echo $! > "$WORK/http.pid" )
  sleep 1
  curl -fsS -o /dev/null "http://127.0.0.1:8897/$NAME" || { bad "测试用 HTTP 服务没起来"; return; }
  T="$(token)"
  resp=$(curl -s -X POST -H "Authorization: Bearer $T" -H 'Content-Type: application/json' \
    -d '{"args":[{"type":"http","uris":["http://127.0.0.1:8897/'"$NAME"'"],"saveDir":"'"$SAVE"'"}]}' \
    "http://127.0.0.1:$PORT/rpc/command/command:createTask")
  echo "  createTask -> $resp"
  landed=0
  for i in $(seq 1 40); do
    if [ -f "$SAVE/$NAME" ] && [ "$(sha256sum "$SAVE/$NAME" | awk '{print $1}')" = "$SHA" ]; then
      ok "文件落盘且 sha256 一致（${i}s，$((3145728/1024))KiB）"; landed=1; break
    fi
    sleep 1
  done
  if [ "$landed" = "0" ]; then
    bad "文件未按预期落盘"
    curl -s -X POST -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d '{"args":[]}' \
      "http://127.0.0.1:$PORT/rpc/query/query:listTasks" | head -c 500; echo
  fi
  echo "  运行身份：$(stat -c '%U:%G' "$SAVE/$NAME" 2>/dev/null)  文件名：$NAME"
  kill "$(cat "$WORK/http.pid")" 2>/dev/null
}

stage_lifecycle() {
  head2 "阶段 5：生命周期"
  before=$(md5sum "$PKGVAR/data/operator-token" 2>/dev/null | awk '{print $1}')
  appcenter-cli stop "$APPNAME" >/dev/null 2>&1; sleep 4
  st=$(appcenter-cli status "$APPNAME" 2>/dev/null)
  [ "$st" != "running" ] && ok "stop 后 status = $st" || bad "stop 后仍在 running"
  if ss -ltn | grep -qE "[:.]$PORT[[:space:]]"; then bad "stop 后 $PORT 仍在监听"; else ok "stop 后端口 $PORT 已释放"; fi
  leftover=""
  for p in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
    exe=$(readlink "/proc/$p/exe" 2>/dev/null); [ -n "$exe" ] || continue
    case "$exe" in "$APPDEST/server/bin/"*) leftover="$leftover $p";; esac
  done
  [ -z "$leftover" ] && ok "无残留子进程（node/aria2c/finalize-fs）" || bad "残留进程:$leftover"

  appcenter-cli start "$APPNAME" >/dev/null 2>&1
  ready=0
  for i in $(seq 1 60); do
    code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/healthz" 2>/dev/null)
    [ "$code" = "200" ] && { ok "start 后 ${i}s 重新就绪"; ready=1; break; }
    sleep 1
  done
  [ "$ready" = "1" ] || bad "start 后未就绪"
  st=$(appcenter-cli status "$APPNAME" 2>/dev/null)
  [ "$st" = "running" ] && ok "status = running" || bad "status = $st"
  after=$(md5sum "$PKGVAR/data/operator-token" 2>/dev/null | awk '{print $1}')
  [ "$before" = "$after" ] && ok "重启后登录口令未重新生成" || bad "口令被重新生成"
  ls "$PKGVAR/data/"*.db >/dev/null 2>&1 && ok "重启后任务库仍在（$PKGVAR/data）" || bad "任务库丢失"
}

stage_ops() {
  head2 "阶段 6：运维项（权限/日志/内存/看护）"
  mode=$(stat -c '%a' "$SAVE" 2>/dev/null)
  case "$mode" in 7[0-9][0-9][0-9]|*) ;; esac
  [ "$(( 0$mode & 0005 ))" -ne 0 ] && ok "下载目录权限 $mode（其他用户可进入）" || bad "下载目录权限 $mode（缺 o+rx）"
  f=$(ls -1 "$SAVE"/*.bin 2>/dev/null | head -1)
  if [ -n "$f" ]; then
    fmode=$(stat -c '%a' "$f")
    [ "$(( 0$fmode & 0004 ))" -ne 0 ] && ok "下载文件权限 $fmode（其他用户可读）" || bad "下载文件权限 $fmode（缺 o+r）"
  else
    echo "  [SKIP] 下载目录里没有 .bin 文件（先跑 e2e 阶段）"
  fi
  pid=$(cat "$PKGVAR/perm-fix.pid" 2>/dev/null)
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && ok "权限修正轮询在运行（pid=$pid）" || bad "权限修正轮询未运行"
  np=$(cat "$PKGVAR/app.pid" 2>/dev/null)
  if [ -n "$np" ] && tr '\0' ' ' < "/proc/$np/cmdline" 2>/dev/null | grep -q -- "--max-old-space-size="; then
    ok "node 内存上限已生效（$(tr '\0' ' ' < "/proc/$np/cmdline" | grep -o -- '--max-old-space-size=[0-9]*')）"
  else
    bad "node 未带 --max-old-space-size"
  fi
  [ -f "$LOG_FILE.1" ] && ok "历史日志已轮转（info.log.1 存在）" || echo "  [SKIP] 还没有轮转过的日志（未超过上限）"
  wiz="/var/apps/$APPNAME/wizard/uninstall"
  if [ -f "$wiz" ] && grep -q 'wizard_uninstall_mode' "$wiz"; then
    ok "卸载向导存在（保留/完全两种模式）"
  else
    bad "缺少 wizard/uninstall 或字段名不对（$wiz）"
  fi
}

stage_status
case "$STAGE" in
  ops)       stage_ops ;;
  endpoints) stage_endpoints ;;
  auth)      stage_auth ;;
  e2e)       stage_e2e ;;
  lifecycle) stage_lifecycle ;;
  all)       stage_endpoints; stage_auth; stage_e2e; stage_lifecycle; stage_ops ;;
esac
echo
echo "=== 结果：PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" = "0" ]
