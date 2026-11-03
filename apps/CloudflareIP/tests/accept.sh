#!/bin/bash
# ==============================================================================
# CloudflareIP 验收阶梯 —— 安装到真机后跑：bash tests/accept.sh all
#
# 规范见 FnFactory/specs/acceptance.md。分层顺序是依赖顺序，前一层不过就不该看下一层：
#   1 status      应用在跑
#   2 endpoints   首页 / /api/state / 局域网 IP 都能通
#   3 auth        同源护栏：跨站 Origin 必须被拒（负例），本机回环放行（正例）
#   4 e2e         真实业务：加域名 → 起测 → 出候选 → 写 hosts → 断言受管区块 → 还原
#   5 lifecycle   stop 后端口释放、无残留进程；start 后就绪
#   6 ops         目录/权限、日志轮转、配置留存
#
# 也可单跑某一阶段：bash tests/accept.sh endpoints
# 环境变量：
#   CFIP_E2E_DOMAIN   端到端用来测速的域名（默认 www.cloudflare.com；必须真的走 Cloudflare）
#   CFIP_E2E_TIMEOUT  端到端等候选的秒数上限（默认 120；网络差就调大）
#   CFIP_KEEP_HOSTS=1 端到端结束后不改回（默认会 restore 还原）
# ==============================================================================
set -u

APPNAME="CloudflareIP"
PKGVAR="${TRIM_PKGVAR:-/vol1/@appdata/$APPNAME}"
APPDEST="${TRIM_APPDEST:-/var/apps/$APPNAME/target}"
CONF="$PKGVAR/config.env"
LOG_FILE="$PKGVAR/info.log"
STAGE="${1:-all}"
PASS=0; FAIL=0

PORT=26890
CFIP_WRITE=1
if [ -r "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF"
fi
BASE="http://127.0.0.1:${CFIP_PORT:-$PORT}"
E2E_DOMAIN="${CFIP_E2E_DOMAIN:-www.cloudflare.com}"
E2E_TIMEOUT="${CFIP_E2E_TIMEOUT:-120}"

ok()    { PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$1"; }
bad()   { FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$1"; }
skip()  { printf '  [SKIP] %s\n' "$1"; }
head2() { printf '\n── %s ──\n' "$1"; }
lan_ip() { ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -n 1; }
jget() { python3 -c 'import json,sys;d=json.load(sys.stdin);print(eval(sys.argv[1],{"d":d}))' "$1" 2>/dev/null; }

stage_status() {
  head2 "阶段 1：应用状态"
  st="$(appcenter-cli status "$APPNAME" 2>/dev/null)"
  [ "$st" = "running" ] && ok "appcenter status = running" || bad "status = $st"
  pid="$(cat "$PKGVAR/app.pid" 2>/dev/null)"
  if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
    exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null)"
    [ "$exe" = "$(readlink -f "$APPDEST/bin/cloudflareip" 2>/dev/null)" ] \
      && ok "pid=$pid 的 /proc/pid/exe 就是包内二进制（身份校验成立）" \
      || bad "pid=$pid 指向的 exe 不是包内二进制：$exe"
  else
    bad "pid 文件缺失或进程不在（$PKGVAR/app.pid）"
  fi
}

stage_endpoints() {
  head2 "阶段 2：端点"
  code="$(curl -s -o /dev/null -w '%{http_code}' "$BASE/")"
  [ "$code" = "200" ] && ok "首页 = 200" || bad "首页 = $code"
  body="$(curl -s -m 5 "$BASE/api/state")"
  case "$body" in
    \{*) if [ "$(printf '%s' "$body" | jget 'd.get("mode")')" = "write" ] || [ "$(printf '%s' "$body" | jget 'd.get("mode")')" = "preview" ]; then
           ok "/api/state 返回状态快照（mode=$(printf '%s' "$body" | jget 'd.get("mode")')，域名 $(printf '%s' "$body" | jget 'len(d.get("domains") or [])') 个）"
         else
           bad "/api/state 返回体缺少 mode 字段"
         fi ;;
    *) bad "/api/state 不是 JSON：$(printf '%s' "$body" | head -c 80)" ;;
  esac
  hosts="$(curl -s -m 5 "$BASE/api/hosts")"
  case "$hosts" in
    \{*) ok "/api/hosts 可读（managed=$(printf '%s' "$hosts" | jget 'len(d.get("managed") or [])') 条受管记录）" ;;
    *)   bad "/api/hosts 不可用" ;;
  esac
  ip="$(lan_ip)"
  if [ -n "$ip" ]; then
    code="$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://$ip:${CFIP_PORT:-$PORT}/")"
    [ "$code" = "200" ] && ok "局域网 IP 访问 = 200（$ip，证明监听不是 127.0.0.1）" || bad "局域网 $ip = $code"
  else
    skip "取不到局域网 IP"
  fi
}

stage_auth() {
  head2 "阶段 3：同源护栏（本工具没有登录口令，护栏是唯一的入口防线）"
  code="$(curl -s -o /dev/null -w '%{http_code}' -H 'Origin: http://evil.example' "$BASE/api/state")"
  [ "$code" = "403" ] && ok "跨站 Origin 被拒（403）" || bad "跨站 Origin 返回 $code（应为 403）"
  code="$(curl -s -o /dev/null -w '%{http_code}' -H "Origin: $BASE" "$BASE/api/state")"
  [ "$code" = "200" ] && ok "同源 Origin 放行（200）" || bad "同源 Origin 返回 $code（应为 200）"
  code="$(curl -s -o /dev/null -w '%{http_code}' -X GET "$BASE/api/apply")"
  [ "$code" = "405" ] && ok "写接口拒绝 GET（405）" || bad "/api/apply 的 GET 返回 $code（应为 405）"
}

stage_e2e() {
  head2 "阶段 4：端到端（加域名 → 起测 → 出候选 → 写 hosts → 还原）"
  if [ "${CFIP_WRITE:-1}" != "1" ]; then
    skip "CFIP_WRITE=0（预览模式），端到端写 hosts 不适用"
    return 0
  fi
  orig_domains="$(curl -s -m 5 "$BASE/api/state" | jget 'json.dumps(d.get("domains") or [])')"
  echo "  · 当前域名列表：${orig_domains:-[]}"

  body="$(python3 -c 'import json,sys;print(json.dumps({"domains":[sys.argv[1]]}))' "$E2E_DOMAIN")"
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d "$body" "$BASE/api/domains")"
  [ "$code" = "200" ] && ok "添加域名 $E2E_DOMAIN（200）" || { bad "添加域名返回 $code"; return 1; }

  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
            -d "{\"domain\":\"$E2E_DOMAIN\",\"screen_only\":true}" "$BASE/api/test")"
  case "$code" in
    202|409) ok "起测请求被接受（$code）" ;;
    *)       bad "起测返回 $code" ;;
  esac

  echo "  · 等待候选（最多 ${E2E_TIMEOUT}s，真实出网测速）"
  waited=0; cand=0; note=""
  while [ "$waited" -lt "$E2E_TIMEOUT" ]; do
    snap="$(curl -s -m 5 "$BASE/api/state")"
    cand="$(printf '%s' "$snap" | jget 'sum(len(r.get("candidates") or []) for r in (d.get("results") or []) if r.get("domain")==sys.argv[1])' 2>/dev/null || echo 0)"
    note="$(printf '%s' "$snap" | jget 'd.get("last_error") or ""')"
    [ "${cand:-0}" -gt 0 ] && break
    sleep 3; waited=$((waited + 3))
  done

  if [ "${cand:-0}" -le 0 ]; then
    bad "在 ${E2E_TIMEOUT}s 内没测出任何可用候选（服务端说明：${note:-无}）——网络问题不等于打包问题，可调大 CFIP_E2E_TIMEOUT 重试"
    return 1
  fi
  ok "测出可用候选 ${cand} 条"

  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
            -d "{\"domain\":\"$E2E_DOMAIN\"}" "$BASE/api/apply")"
  [ "$code" = "200" ] && ok "应用优选（写 hosts）返回 200" || bad "应用优选返回 $code"

  managed="$(curl -s -m 5 "$BASE/api/hosts" | jget 'len(d.get("managed") or [])')"
  if [ "${managed:-0}" -gt 0 ]; then
    ok "/api/hosts 显示受管记录 ${managed} 条"
  else
    bad "/api/hosts 里没有受管记录（写入没生效？）"
  fi
  if grep -q '>>> cloudflareip managed block' /etc/hosts 2>/dev/null; then
    ok "/etc/hosts 里出现受管区块，且含 $E2E_DOMAIN $(grep -c "$E2E_DOMAIN" /etc/hosts 2>/dev/null) 处"
  else
    bad "/etc/hosts 里找不到受管区块"
  fi

  if [ "${CFIP_KEEP_HOSTS:-0}" = "1" ]; then
    skip "CFIP_KEEP_HOSTS=1：保留写入结果（不还原）"
  else
    code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/restore")"
    [ "$code" = "200" ] && ok "还原默认（删受管区块）返回 200" || bad "还原返回 $code"
    if grep -q '>>> cloudflareip managed block' /etc/hosts 2>/dev/null; then
      bad "还原后受管区块仍在 /etc/hosts 里"
    else
      ok "还原后受管区块已消失（块外内容按设计未被触碰）"
    fi
  fi

  # 收尾：把域名列表恢复成验收前的样子（只测不污染用户配置）
  body="$(python3 -c 'import json,sys;print(json.dumps({"domains":json.loads(sys.argv[1])}))' "${orig_domains:-[]}")"
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d "$body" "$BASE/api/domains")"
  [ "$code" = "200" ] && ok "域名列表已恢复为验收前状态" || bad "恢复域名列表返回 $code"
}

stage_lifecycle() {
  head2 "阶段 5：生命周期"
  appcenter-cli stop "$APPNAME" >/dev/null 2>&1
  for i in $(seq 1 20); do [ "$(appcenter-cli status "$APPNAME" 2>/dev/null)" = "stopped" ] && break; sleep 1; done
  [ "$(appcenter-cli status "$APPNAME" 2>/dev/null)" = "stopped" ] && ok "stop 后 status = stopped" || bad "stop 后仍不是 stopped"
  ss -ltn 2>/dev/null | grep -qE "[:.]${CFIP_PORT:-$PORT}[[:space:]]" && bad "端口 ${CFIP_PORT:-$PORT} 未释放" || ok "端口 ${CFIP_PORT:-$PORT} 已释放"
  left="$(for p in $(ls /proc | grep -E '^[0-9]+$'); do
            e="$(readlink -f "/proc/$p/exe" 2>/dev/null)"
            case "$e" in "$APPDEST"/bin/cloudflareip) echo "$p" ;; esac
          done | head -n 1)"
  [ -z "$left" ] && ok "无残留进程（/proc 里没有包内二进制）" || bad "仍有残留进程 pid=$left"
  appcenter-cli start "$APPNAME" >/dev/null 2>&1
  for i in $(seq 1 45); do curl -fsS -m 1 "$BASE/" >/dev/null 2>&1 && break; sleep 1; done
  curl -fsS -m 2 "$BASE/" >/dev/null 2>&1 && ok "start 后就绪" || bad "start 后未就绪（看 $LOG_FILE）"
  # 重启后数据还在：配置文件与状态文件属于 PKGVAR，不该被重启抹掉
  [ -s "$PKGVAR/config/config.json" ] && ok "重启后 config.json 仍在（$PKGVAR/config/）" || bad "config.json 丢了"
}

stage_ops() {
  head2 "阶段 6：运维项"
  for d in "$PKGVAR" "$PKGVAR/config" "$PKGVAR/home"; do
    [ -d "$d" ] && ok "目录存在：$d" || bad "缺少目录：$d"
  done
  [ -x "$APPDEST/bin/cloudflareip" ] && ok "包内二进制可执行（0755）" || bad "包内二进制不可执行"
  if [ -s "$APPDEST/share/PROVENANCE.json" ]; then
    ver="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["package_version"])' "$APPDEST/share/PROVENANCE.json" 2>/dev/null)"
    ok "PROVENANCE 可读，包版本 ${ver:-?}"
  else
    skip "没有 share/PROVENANCE.json"
  fi
  v="$("$APPDEST/bin/cloudflareip" help 2>&1 | head -n 1)"
  case "$v" in *"Cloudflare IP"*) ok "二进制自报版本：$v" ;; *) bad "二进制版本行异常：$v" ;; esac
  if [ -f "$LOG_FILE" ]; then
    size="$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)"
    [ "$size" -le 5242880 ] && ok "info.log 在轮转阈值内（$size 字节）" || bad "info.log 已超阈值（$size 字节）"
  else
    skip "还没有 $LOG_FILE"
  fi
  if grep -q 'chmod 0644 "\$CONF"' "$APPDEST/apply-config.sh" 2>/dev/null; then
    ok "apply-config.sh 会显式修文件权限（飞牛安装收尾会把 @appdata 收紧）"
  else
    skip "apply-config.sh 权限自愈检查点不存在（脚本可能已改版）"
  fi
}

[ -d "$PKGVAR" ] || { echo "找不到 $PKGVAR：这台机器上没装 $APPNAME，或 TRIM_PKGVAR 不同" >&2; exit 2; }

case "$STAGE" in
  status)    stage_status ;;
  endpoints) stage_endpoints ;;
  auth)      stage_auth ;;
  e2e)       stage_e2e ;;
  lifecycle) stage_lifecycle ;;
  ops)       stage_ops ;;
  all)       stage_status; stage_endpoints; stage_auth; stage_e2e; stage_lifecycle; stage_ops ;;
  *)         echo "usage: $0 {all|status|endpoints|auth|e2e|lifecycle|ops}"; exit 2 ;;
esac

printf '\n=== 结果：PASS %d / FAIL %d ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
