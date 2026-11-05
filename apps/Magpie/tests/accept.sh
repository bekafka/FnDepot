#!/bin/bash
# ==============================================================================
# Magpie 验收阶梯（在飞牛设备上跑）
#
#   安装后：sudo bash tests/accept.sh all
#   单级：  sudo bash tests/accept.sh status|endpoints|auth|e2e|lifecycle|ops
#
# 判定：任何一条 FAIL 都不算通过（PASS=n FAIL=0 才算）。
# 设计口径（FnFactory specs/acceptance.md）：
#   · 端点和鉴权都要测**局域网 IP**，不能只测 127.0.0.1；
#   · 鉴权要负例（无密钥必须被拒）+ 正例（带密钥成功）；
#   · 端到端断言的是"内容"（mock 上游的固定字符串），不是"HTTP 200 就算过"；
#   · stop 之后端口必须释放、/proc 里不能有本应用的进程。
# ==============================================================================
set -u

APP="Magpie"
APP_DIR="${APP_DIR:-/var/apps/$APP}"
PKGVAR="${PKGVAR:-$(readlink -f "$APP_DIR/var" 2>/dev/null || echo "$APP_DIR/var")}"
APPDEST="${APPDEST:-$(readlink -f "$APP_DIR/target" 2>/dev/null || echo "$APP_DIR/target")}"
MAIN="${MAIN:-$APP_DIR/cmd/main}"
BIN="$APPDEST/bin/magpie"
CONF="$PKGVAR/config.env"
WEB_KEY_FILE="$PKGVAR/web-key"
GW_KEY_FILE="$PKGVAR/gateway-keys.txt"
UI_CONFIG="$APPDEST/ui/config"
MOCK_PORT="${MOCK_PORT:-23999}"
MOCK_LOG="${MOCK_LOG:-/tmp/magpie-accept-mock.log}"

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '  \033[32m[PASS]\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; }
skip() { SKIP=$((SKIP+1)); printf '  \033[33m[SKIP]\033[0m %s\n' "$*"; }

# ── 读配置 ───────────────────────────────────────────────────────────────────
[ -r "$CONF" ] || { echo "读不到 $CONF（应用装好了吗？用 root 跑）" >&2; exit 2; }
# shellcheck disable=SC1090
. "$CONF"
WEB_PORT="${MAGPIE_WEB_PORT:-3430}"
GW_PORT="${MAGPIE_GATEWAY_PORT:-3425}"
LAN_FLAG="${MAGPIE_LAN:-1}"
WEB_KEY="$(tr -d '[:space:]' < "$WEB_KEY_FILE" 2>/dev/null)"
RUN_USER="$(stat -c '%U' "$PKGVAR" 2>/dev/null)"
[ -n "$RUN_USER" ] && [ "$RUN_USER" != "root" ] || RUN_USER="Magpie"
RUN_GROUP="$(stat -c '%G' "$PKGVAR" 2>/dev/null)"
[ -n "$RUN_GROUP" ] || RUN_GROUP="$RUN_USER"

# cmd/main 在应用中心里靠这些变量找路径；脚本手动调用时要给同一套上下文，
# 否则它去看 /var/apps/Magpie 而看不到本机的 $APP_DIR。
export TRIM_PKGVAR="$PKGVAR" TRIM_APPDEST="$APPDEST" TRIM_USERNAME="$RUN_USER" TRIM_GROUPNAME="$RUN_GROUP"

LAN_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -n 1)"
[ -n "${LAN_IP:-}" ] || LAN_IP="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n 1)"
echo "== Magpie 验收：面板 $WEB_PORT / 网关 $GW_PORT / 局域网 $LAN_FLAG / LAN IP ${LAN_IP:-无}"

http_code() { curl -s -o /dev/null -m 5 -w '%{http_code}' "$@" 2>/dev/null; }

as_app() {
  if [ "$(id -u)" = "0" ]; then
    setpriv --reuid="$RUN_USER" --regid="$RUN_GROUP" --init-groups -- env \
      HOME="$PKGVAR/home" XDG_CONFIG_HOME="$PKGVAR/config" XDG_CACHE_HOME="$PKGVAR/cache" \
      XDG_DATA_HOME="$PKGVAR/data" XDG_STATE_HOME="$PKGVAR/state" TMPDIR="$PKGVAR/tmp" \
      MAGPIE_NO_STATS=1 "$@"
  else
    env HOME="$PKGVAR/home" XDG_CONFIG_HOME="$PKGVAR/config" XDG_CACHE_HOME="$PKGVAR/cache" \
      XDG_DATA_HOME="$PKGVAR/data" XDG_STATE_HOME="$PKGVAR/state" TMPDIR="$PKGVAR/tmp" \
      MAGPIE_NO_STATS=1 "$@"
  fi
}

app_pids() {
  local pid exe want
  want="$(readlink -f "$BIN" 2>/dev/null)"
  for pid in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
    [ -r "/proc/$pid/exe" ] || continue
    exe="$(readlink "/proc/$pid/exe" 2>/dev/null)" || continue
    [ "$exe" = "$want" ] && printf '%s\n' "$pid"
  done
}

port_open() { ss -ltn 2>/dev/null | grep -qE "[:.]$1[[:space:]]"; }

# ── 1. 状态 ──────────────────────────────────────────────────────────────────
level_status() {
  echo "-- 1. 状态"
  local st
  st="$("$MAIN" status >/dev/null 2>&1; echo $?)"
  [ "$st" = "0" ] && ok "cmd/main status = 0（运行中）" || bad "cmd/main status = $st（期望 0）"
  if command -v appcenter-cli >/dev/null 2>&1 && [ "$(id -u)" = "0" ]; then
    local out
    out="$(appcenter-cli status "$APP" 2>&1 | tr -d '\r' | grep -v '^[[:space:]]*$' | tail -n 1)"
    case "$out" in
      *running*) ok "appcenter-cli status = $out" ;;
      *) bad "appcenter-cli status = ${out:-空}" ;;
    esac
  else
    skip "appcenter-cli status（不是 root 或没装 appcenter-cli）"
  fi
  local n; n="$(app_pids | wc -l)"
  [ "$n" -ge 1 ] && ok "本应用进程数 = $n（exe=$BIN）" || bad "没有找到本应用的进程"
}

# ── 2. 端点 ──────────────────────────────────────────────────────────────────
level_endpoints() {
  echo "-- 2. 端点"
  local code page
  code="$(http_code "http://127.0.0.1:$WEB_PORT/")"
  [ "$code" = "401" ] && ok "面板无密钥 = 401（负例）" || bad "面板无密钥 = $code（期望 401）"

  code="$(http_code "http://127.0.0.1:$WEB_PORT/?k=$WEB_KEY")"
  case "$code" in 303|302|200) ok "面板带密钥 = $code（重定向/直接 200）" ;; *) bad "面板带密钥 = $code" ;; esac

  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    --data-urlencode "key=$WEB_KEY" --data-urlencode "back=/" \
    "http://127.0.0.1:$WEB_PORT/_magpie/sign-in")"
  [ "$code" = "303" ] && ok "登录页表单：正确密钥 = 303（种 400 天 cookie）" || bad "登录页表单（正确密钥）= $code"
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    --data "key=definitely-wrong-key&back=/" "http://127.0.0.1:$WEB_PORT/_magpie/sign-in")"
  [ "$code" = "401" ] && ok "登录页表单：错误密钥 = 401（负例）" || bad "登录页表单（错误密钥）= $code"

  rm -f /tmp/magpie-accept-cj
  page="$(curl -s -L -m 10 -c /tmp/magpie-accept-cj -b /tmp/magpie-accept-cj \
      -o /tmp/magpie-accept-page.html -w '%{http_code}' "http://127.0.0.1:$WEB_PORT/?k=$WEB_KEY")"
  [ "$page" = "200" ] && ok "面板首屏（带 cookie）= 200" || bad "面板首屏（带 cookie）= $page"
  grep -qi '<title>magpie</title>' /tmp/magpie-accept-page.html 2>/dev/null \
    && ok "首屏 HTML 是 magpie 页面" || bad "首屏 HTML 不含 <title>magpie</title>"

  local asset
  asset="$(grep -oE '(src|href)="[^"]+\.(js|css)(\?[^"]*)?"' /tmp/magpie-accept-page.html 2>/dev/null \
    | head -n 1 | sed -E 's/^(src|href)="//; s/"$//')"
  if [ -n "$asset" ]; then
    code="$(curl -s -o /dev/null -m 10 -b /tmp/magpie-accept-cj -w '%{http_code}' "http://127.0.0.1:$WEB_PORT/$asset")"
    [ "$code" = "200" ] && ok "静态资源 /$asset = 200" || bad "静态资源 /$asset = $code"
  else
    skip "页面里没找到 js/css 静态资源引用"
  fi

  code="$(http_code "http://127.0.0.1:$GW_PORT/")"
  [ "$code" = "200" ] && ok "网关根路径（回环）= 200" || bad "网关根路径 = $code"

  code="$(http_code "http://127.0.0.1:$GW_PORT/v1/models")"
  [ "$code" = "200" ] && ok "网关 /v1/models（回环）= 200" || bad "网关 /v1/models = $code"

  if [ -n "${LAN_IP:-}" ] && [ "$LAN_IP" != "127.0.0.1" ]; then
    code="$(http_code "http://$LAN_IP:$WEB_PORT/?k=$WEB_KEY")"
    case "$code" in 200|303|302) ok "面板经局域网 IP = $code" ;; *) bad "面板经局域网 IP = $code" ;; esac
  else
    skip "没有局域网 IP，跳过局域网面板检查"
  fi
}

# ── 3. 鉴权 ──────────────────────────────────────────────────────────────────
level_auth() {
  echo "-- 3. 鉴权"
  local code
  if [ "$LAN_FLAG" = "1" ]; then
    grep -q 'sk-magpie-key-' "$GW_KEY_FILE" 2>/dev/null \
      && ok "网关密钥文件存在且含密钥" || bad "局域网共享开启但 $GW_KEY_FILE 里没有密钥"
    local gwkey
    gwkey="$(grep -o 'sk-magpie-key-[0-9a-f]*' "$GW_KEY_FILE" 2>/dev/null | head -n 1)"

    if [ -n "${LAN_IP:-}" ] && [ "$LAN_IP" != "127.0.0.1" ]; then
      code="$(http_code "http://$LAN_IP:$GW_PORT/v1/models")"
      case "$code" in 401|403) ok "远端无密钥 = $code（负例）" ;; *) bad "远端无密钥 = $code（期望 401/403）" ;; esac

      code="$(http_code -H "Authorization: Bearer wrong-key" "http://$LAN_IP:$GW_PORT/v1/models")"
      case "$code" in 401|403) ok "远端错误密钥 = $code（负例）" ;; *) bad "远端错误密钥 = $code（期望 401/403）" ;; esac

      if [ -n "$gwkey" ]; then
        code="$(http_code -H "Authorization: Bearer $gwkey" "http://$LAN_IP:$GW_PORT/v1/models")"
        [ "$code" = "200" ] && ok "远端正确密钥 = 200（正例）" || bad "远端正确密钥 = $code"
      else
        bad "拿不到网关密钥，无法验证正例"
      fi
    else
      skip "没有局域网 IP，跳过远端鉴权"
    fi
  else
    if [ -n "${LAN_IP:-}" ] && [ "$LAN_IP" != "127.0.0.1" ]; then
      code="$(http_code "http://$LAN_IP:$GW_PORT/v1/models")"
      [ "$code" = "000" ] && ok "局域网共享关闭：远端连不上（000）" || bad "局域网共享关闭但远端返回 $code"
    else
      skip "没有局域网 IP，跳过局域网关闭检查"
    fi
    skip "网关密钥文件（局域网共享关闭，不要求）"
  fi

  local perm
  perm="$(stat -c '%a' "$WEB_KEY_FILE" 2>/dev/null || echo none)"
  [ "$perm" = "600" ] && ok "面板密钥文件权限 = 600" || bad "面板密钥文件权限 = $perm（期望 600）"
}

# ── 4. 端到端 ────────────────────────────────────────────────────────────────
start_mock() {
  cat > /tmp/magpie-accept-mock.py <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, obj, code=200):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header('Content-Type','application/json')
        self.send_header('Content-Length', str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        if self.path.rstrip('/').endswith('/v1/models'):
            self._send({"object":"list","data":[{"id":"mock-gpt","object":"model","created":1,"owned_by":"mock"}]})
        else:
            self._send({"error":{"message":"not found"}}, 404)
    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        body = json.loads(self.rfile.read(n) or b'{}')
        user = (body.get('messages') or [{}])[-1].get('content','')
        self._send({"id":"chatcmpl-mock","object":"chat.completion","created":1,"model":body.get("model"),
            "choices":[{"index":0,"message":{"role":"assistant","content":"MAGPIE-ACCEPT-OK " + str(user)},"finish_reason":"stop"}],
            "usage":{"prompt_tokens":7,"completion_tokens":5,"total_tokens":12}})
HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
PY
  python3 /tmp/magpie-accept-mock.py "$MOCK_PORT" > "$MOCK_LOG" 2>&1 &
  MOCK_PID=$!
  sleep 1
}

stop_mock() { [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null; rm -f /tmp/magpie-accept-mock.py; }

level_e2e() {
  echo "-- 4. 端到端（网关 → provider → 上游）"
  command -v python3 >/dev/null 2>&1 || { skip "没有 python3，跳过端到端"; return; }
  if port_open "$MOCK_PORT"; then bad "mock 上游端口 $MOCK_PORT 已被占用"; return; fi
  start_mock
  local out body
  out="$(as_app "$BIN" provider add "acceptmock" url="http://127.0.0.1:$MOCK_PORT/v1" key=sk-mock models=mock-gpt 2>&1)"
  case "$out" in
    *added*|*added\ acceptmock*) ok "provider add acceptmock：$(printf '%s' "$out" | head -n 1)" ;;
    *) bad "provider add 失败：$out" ;;
  esac

  body="$(curl -s -m 20 -H 'Authorization: Bearer magpie' -H 'Content-Type: application/json' \
    -d '{"model":"acceptmock/mock-gpt","messages":[{"role":"user","content":"e2e-ping"}]}' \
    "http://127.0.0.1:$GW_PORT/v1/chat/completions")"
  case "$body" in
    *MAGPIE-ACCEPT-OK*) ok "网关补全返回 mock 上游内容（$(printf '%s' "$body" | head -c 120)…）" ;;
    *) bad "网关补全没有拿到 mock 内容：$(printf '%s' "$body" | head -c 300)" ;;
  esac

  if [ "$LAN_FLAG" = "1" ] && [ -n "${LAN_IP:-}" ] && [ "$LAN_IP" != "127.0.0.1" ]; then
    local gwkey
    gwkey="$(grep -o 'sk-magpie-key-[0-9a-f]*' "$GW_KEY_FILE" 2>/dev/null | head -n 1)"
    body="$(curl -s -m 20 -H "Authorization: Bearer $gwkey" -H 'Content-Type: application/json' \
      -d '{"model":"acceptmock/mock-gpt","messages":[{"role":"user","content":"lan-e2e"}]}' \
      "http://$LAN_IP:$GW_PORT/v1/chat/completions")"
    case "$body" in
      *MAGPIE-ACCEPT-OK*) ok "经局域网 + 网关密钥的补全也通" ;;
      *) bad "经局域网的补全失败：$(printf '%s' "$body" | head -c 300)" ;;
    esac
  fi

  out="$(as_app "$BIN" provider rm "acceptmock" 2>&1)"
  case "$out" in *removed*) ok "清理测试 provider" ;; *) bad "清理 provider 失败：$out" ;; esac
  stop_mock
}

# ── 5. 生命周期 ──────────────────────────────────────────────────────────────
level_lifecycle() {
  echo "-- 5. 生命周期"
  local before after code
  before="$(sha256sum "$WEB_KEY_FILE" 2>/dev/null | awk '{print $1}')"
  "$MAIN" stop >/dev/null 2>&1
  sleep 2
  if port_open "$WEB_PORT" || port_open "$GW_PORT"; then
    bad "stop 后端口仍被占用（面板 $WEB_PORT / 网关 $GW_PORT）"
  else
    ok "stop 后端口已释放"
  fi
  [ -z "$(app_pids)" ] && ok "stop 后没有残留进程" || bad "stop 后仍有进程：$(app_pids | tr '\n' ' ')"

  "$MAIN" start >/dev/null 2>&1
  sleep 1
  [ "$("$MAIN" status >/dev/null 2>&1; echo $?)" = "0" ] && ok "start 后 status = 0" || bad "start 后 status ≠ 0"
  code="$(http_code "http://127.0.0.1:$WEB_PORT/?k=$WEB_KEY")"
  case "$code" in 200|303|302) ok "重启后面板可用（$code）" ;; *) bad "重启后面板 = $code" ;; esac
  after="$(sha256sum "$WEB_KEY_FILE" 2>/dev/null | awk '{print $1}')"
  [ -n "$before" ] && [ "$before" = "$after" ] && ok "重启没有重生成面板密钥" || bad "面板密钥在重启后变了"
}

# ── 6. 运维项 ────────────────────────────────────────────────────────────────
level_ops() {
  echo "-- 6. 运维项"
  local perm
  for f in "$WEB_KEY_FILE" "$CONF"; do
    perm="$(stat -c '%a' "$f" 2>/dev/null || echo none)"
    [ "$perm" = "600" ] && ok "$(basename "$f") 权限 = 600" || bad "$(basename "$f") 权限 = $perm"
  done
  if [ "$LAN_FLAG" = "1" ]; then
    perm="$(stat -c '%a' "$GW_KEY_FILE" 2>/dev/null || echo none)"
    [ "$perm" = "600" ] && ok "gateway-keys.txt 权限 = 600" || bad "gateway-keys.txt 权限 = $perm"
  fi
  [ -f "$PKGVAR/info.log" ] && ok "运行日志存在（$PKGVAR/info.log）" || bad "没有运行日志"
  if [ -f "$UI_CONFIG" ]; then
    grep -q "\"port\": \"$WEB_PORT\"" "$UI_CONFIG" && ok "桌面入口端口 = $WEB_PORT" || bad "桌面入口端口不是 $WEB_PORT"
    grep -q "\"url\": \"/?k=$WEB_KEY\"" "$UI_CONFIG" \
      && ok "桌面入口 URL 带面板密钥（字面量，飞牛入口不接受占位符）" || bad "桌面入口 URL 没带面板密钥"
    grep -q "\"type\": \"url\"" "$UI_CONFIG" && ok "桌面入口 type = url（保留查询串）" || bad "桌面入口 type 不是 url"
  else
    bad "缺少桌面入口 $UI_CONFIG"
  fi
  if [ -f "$PKGVAR/config/magpie/settings.json" ]; then
    grep -q '"lan"' "$PKGVAR/config/magpie/settings.json" && ok "settings.json 已写入 lan" || bad "settings.json 缺 lan"
    grep -q "\"port\": $GW_PORT" "$PKGVAR/config/magpie/settings.json" \
      && ok "settings.json 网关端口 = $GW_PORT" || bad "settings.json 网关端口不是 $GW_PORT"
  else
    bad "缺少 settings.json"
  fi
  [ -L /usr/local/bin/magpie-cli ] && ok "命令行入口 /usr/local/bin/magpie-cli 已创建" \
    || skip "没有 /usr/local/bin/magpie-cli（usr-local-linker 未生效）"
  local pid env_mem
  pid="$(app_pids | head -n 1)"
  if [ -n "$pid" ]; then
    env_mem="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -c '^MAGPIE_NO_STATS=1' || true)"
    [ "${env_mem:-0}" -ge 1 ] && ok "服务进程带 MAGPIE_NO_STATS=1（不打点）" || skip "进程环境里没有 MAGPIE_NO_STATS"
  fi
}

case "${1:-all}" in
  all)
    level_status; level_endpoints; level_auth; level_e2e; level_lifecycle; level_ops ;;
  status)    level_status ;;
  endpoints) level_endpoints ;;
  auth)      level_auth ;;
  e2e)       level_e2e ;;
  lifecycle) level_lifecycle ;;
  ops)       level_ops ;;
  *) echo "usage: $0 all|status|endpoints|auth|e2e|lifecycle|ops"; exit 2 ;;
esac

echo
echo "== 结果：PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
