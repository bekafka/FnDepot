#!/bin/bash
# ==============================================================================
# PhotoCraft 验收阶梯 —— 安装到真机后跑：bash tests/accept.sh all
#
# 分层顺序是依赖顺序，前一层不过就不该看下一层：
#   1 status      应用在跑，且 pid 身份就是包内二进制
#   2 endpoints   /healthz、首页、预压缩分片、胶水、字体清单都通；未知路径真 404
#   3 headers     .wasm 是 application/wasm；分片原字节直出（无 Content-Encoding）；
#                 固定名 no-cache、哈希名强缓存
#   4 lifecycle   stop 后端口释放、无残留；start 后重新就绪；配置不被重写
#   5 ops         数据目录/日志权限与留存
#
# 也可单跑某一阶段：bash tests/accept.sh endpoints
# ==============================================================================
set -u

APPNAME="PhotoCraft"
PKGVAR="${TRIM_PKGVAR:-/vol1/@appdata/$APPNAME}"
APPDEST="${TRIM_APPDEST:-/var/apps/$APPNAME/target}"
CONF="$PKGVAR/config.env"
LOG_FILE="$PKGVAR/info.log"
STAGE="${1:-all}"
PASS=0; FAIL=0

PORT=28200
if [ -r "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF"
fi
PORT="${PHOTOCRAFT_PORT:-$PORT}"
BASE="http://127.0.0.1:${PORT}"

ok()    { PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$1"; }
bad()   { FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$1"; }
skip()  { printf '  [SKIP] %s\n' "$1"; }
head2() { printf '\n── %s ──\n' "$1"; }
lan_ip() { ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -n 1; }

stage_status() {
  head2 "阶段 1：应用状态"
  st="$(appcenter-cli status "$APPNAME" 2>/dev/null)"
  [ "$st" = "running" ] && ok "appcenter status = running" || bad "status = $st"
  pid="$(cat "$PKGVAR/app.pid" 2>/dev/null)"
  if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
    exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null)"
    [ "$exe" = "$(readlink -f "$APPDEST/bin/photocraft-web" 2>/dev/null)" ] \
      && ok "pid=$pid 的 /proc/pid/exe 就是包内二进制（身份校验成立）" \
      || bad "pid=$pid 指向的 exe 不是包内二进制：$exe"
  else
    bad "pid 文件缺失或进程不在（$PKGVAR/app.pid）"
  fi
}

stage_endpoints() {
  head2 "阶段 2：端点"
  code="$(curl -s -o /dev/null -w '%{http_code}' "$BASE/healthz")"
  [ "$code" = "200" ] && ok "/healthz = 200" || bad "/healthz = $code"

  body="$(curl -s -m 8 "$BASE/")"
  case "$body" in
    *photocraft_canvas*) ok "首页 200 且含画布元素（编辑器页面）" ;;
    *) bad "首页内容异常（缺 photocraft_canvas）：$(printf '%s' "$body" | head -c 80)" ;;
  esac

  parts="$(curl -s -m 8 "$BASE/app/parts.txt")"
  first="$(printf '%s\n' "$parts" | sed -n '2p')"
  if [ -n "$first" ]; then
    code="$(curl -s -o /dev/null -w '%{http_code}' "$BASE/app/$first")"
    [ "$code" = "200" ] && ok "wasm 分片 app/$first = 200" || bad "wasm 分片 app/$first = $code"
  else
    bad "app/parts.txt 里读不到分片名"
  fi

  code="$(curl -s -o /dev/null -w '%{http_code}' "$BASE/app/photocraft-web.js")"
  [ "$code" = "200" ] && ok "应用胶水 app/photocraft-web.js = 200" || bad "胶水 = $code"

  code="$(curl -s -o /dev/null -w '%{http_code}' "$BASE/fonts/manifest.txt")"
  [ "$code" = "200" ] && ok "中文字体清单 fonts/manifest.txt = 200" || bad "字体清单 = $code"

  # 负例：未知路径必须 404，不能是 SPA 兜底的 200
  code="$(curl -s -o /dev/null -w '%{http_code}' "$BASE/definitely-not-a-file-$$.js")"
  [ "$code" = "404" ] && ok "未知路径 = 404（未做 SPA 兜底）" || bad "未知路径返回 $code（应为 404）"

  ip="$(lan_ip)"
  if [ -n "$ip" ]; then
    code="$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://$ip:$PORT/healthz")"
    [ "$code" = "200" ] && ok "局域网地址 http://$ip:$PORT/healthz = 200（监听不是只回环）" \
                        || bad "局域网地址不可用：$code（检查 wizard_host 是否 0.0.0.0）"
  else
    skip "取不到局域网 IP"
  fi
}

stage_headers() {
  head2 "阶段 3：响应头"
  boot_wasm="$(curl -s -m 8 "$BASE/" | grep -o 'photocraft-web-boot-[a-f0-9]*_bg\.wasm' | head -n 1)"
  if [ -n "$boot_wasm" ]; then
    ct="$(curl -sI -m 8 "$BASE/$boot_wasm" | tr -d '\r' | grep -i '^content-type:' | head -n 1 | sed 's/.*:[[:space:]]*//')"
    case "$ct" in
      application/wasm*) ok "boot wasm 的 Content-Type = $ct" ;;
      *) bad "boot wasm 的 Content-Type = ${ct:-缺失}（必须是 application/wasm）" ;;
    esac
  else
    bad "首页里找不到 boot wasm 文件名"
  fi

  parts="$(curl -s -m 8 "$BASE/app/parts.txt")"
  first="$(printf '%s\n' "$parts" | sed -n '2p')"
  if [ -n "$first" ]; then
    hdr="$(curl -sI -m 8 "$BASE/app/$first" | tr -d '\r')"
    if printf '%s' "$hdr" | grep -qi '^content-encoding:'; then
      bad "分片带了 Content-Encoding（页面会解压失败）"
    else
      ok "分片无 Content-Encoding（按原字节直出）"
    fi
    printf '%s' "$hdr" | grep -qi '^cache-control:.*immutable' \
      && ok "分片 Cache-Control 含 immutable" || bad "分片缺少 immutable 缓存头"
  fi

  cc="$(curl -sI -m 8 "$BASE/index.html" | tr -d '\r' | grep -i '^cache-control:' | head -n 1)"
  case "$cc" in
    *no-cache*) ok "index.html 为 no-cache" ;;
    *) bad "index.html 缓存头异常：${cc:-缺失}" ;;
  esac
}

stage_lifecycle() {
  head2 "阶段 4：生命周期"
  before="$(sha256sum "$CONF" 2>/dev/null | awk '{print $1}')"
  MAIN="/var/apps/$APPNAME/cmd/main"
  "$MAIN" stop >/dev/null 2>&1
  sleep 2
  ss -ltn 2>/dev/null | grep -qE "[:.]$PORT[[:space:]]" \
    && bad "stop 后端口 $PORT 仍在监听" || ok "stop 后端口 $PORT 已释放"
  pgrep -f "bin/photocraft-web" >/dev/null 2>&1 \
    && bad "stop 后仍有 photocraft-web 进程残留" || ok "stop 后无残留进程"
  "$MAIN" start >/dev/null 2>&1
  sleep 2
  code="$(curl -s -o /dev/null -w '%{http_code}' -m 5 "$BASE/healthz")"
  [ "$code" = "200" ] && ok "start 后 /healthz 重新就绪" || bad "start 后 /healthz = $code"
  after="$(sha256sum "$CONF" 2>/dev/null | awk '{print $1}')"
  [ "$before" = "$after" ] && ok "重启未改写 config.env（幂等）" || bad "config.env 被重启改写"
}

stage_ops() {
  head2 "阶段 5：运维项"
  [ -s "$CONF" ] && ok "config.env 存在（端口 $(sed -n 's/^PHOTOCRAFT_PORT=//p' "$CONF")）" || bad "缺少 config.env"
  [ -f "$LOG_FILE" ] && ok "info.log 存在（$(stat -c%s "$LOG_FILE" 2>/dev/null) 字节）" || bad "缺少 info.log"
  [ -f "$APPDEST/webroot/index.html" ] && ok "payload 站点就位（$APPDEST/webroot）" || bad "站点目录缺失"
  perm="$(stat -c%a "$APPDEST/bin/photocraft-web" 2>/dev/null)"
  { [ -n "$perm" ] && [ $((8#$perm & 8#111)) -ne 0 ]; } && ok "二进制可执行（$perm）" || bad "二进制不可执行（$perm）"
  [ -s "$APPDEST/share/PROVENANCE.json" ] && ok "溯源文件存在" || skip "缺少 PROVENANCE.json"
}

case "$STAGE" in
  all)        stage_status; stage_endpoints; stage_headers; stage_lifecycle; stage_ops ;;
  status)     stage_status ;;
  endpoints)  stage_endpoints ;;
  headers)    stage_headers ;;
  lifecycle)  stage_lifecycle ;;
  ops)        stage_ops ;;
  *) echo "usage: $0 {all|status|endpoints|headers|lifecycle|ops}"; exit 2 ;;
esac

printf '\n合计：PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
