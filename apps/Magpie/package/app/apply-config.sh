#!/bin/bash
# ==============================================================================
# Magpie · 向导值 → 运行时配置（install_callback / config_callback / upgrade_callback 共用）
#
#   用法：apply-config.sh <install|config|upgrade>
#
# 设计要点：
#   · 端口一律当不可信字符串重新校验；非法值显式失败，不静默用默认值。
#   · config/upgrade 模式下「留空 = 保持当前值」：应用设置页误保存不会把端口改回去。
#   · 端口只落 ${TRIM_PKGVAR}/config.env，由 cmd/main 读取 —— 应用中心不会把
#     向导值传给 cmd/main，这是官方契约，必须自己转存。
#   · 「局域网共享」写的是 magpie 自己的 settings.json 的 lan 字段：
#     它决定网关监听 0.0.0.0 还是 127.0.0.1，同时决定远端是否强制网关密钥。
#     只把 MAGPIE_ADDR 写成 0.0.0.0 而 lan=false 会得到一个免鉴权的开放代理，
#     所以这里永远只让 settings.json 决定监听范围。
#   · 桌面入口（app/ui/config）的 URL 要带上面板密钥（字面量；飞牛入口不替换查询串里的占位符）。
# ==============================================================================
set -u

MODE="${1:-install}"
APPNAME="Magpie"
PKGVAR="${TRIM_PKGVAR:?TRIM_PKGVAR is required}"
APPDEST="${TRIM_APPDEST:?TRIM_APPDEST is required}"
RUN_USER="${TRIM_USERNAME:-$APPNAME}"
RUN_GROUP="${TRIM_GROUPNAME:-$APPNAME}"

CONF="$PKGVAR/config.env"
LOG="$PKGVAR/info.log"
WEB_KEY_FILE="$PKGVAR/web-key"
GWKEY_FILE="$PKGVAR/gateway-keys.txt"
UI_CONFIG="$APPDEST/ui/config"
BIN="$APPDEST/bin/magpie"
XDG_CONFIG="$PKGVAR/config"
SETTINGS="$XDG_CONFIG/magpie/settings.json"

DEFAULT_WEB_PORT=3430
DEFAULT_GATEWAY_PORT=3425

log() {
  printf '%s - [config:%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$MODE" "$*" >> "$LOG" 2>/dev/null || true
  if [ -n "${TRIM_TEMP_LOGFILE:-}" ]; then
    printf '%s - [config:%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$MODE" "$*" >> "$TRIM_TEMP_LOGFILE" 2>/dev/null || true
  fi
}

is_root() { [ "$(id -u)" = "0" ]; }

# 以应用身份执行（install_callback 可能是 root）。飞牛上没有 runuser，用 setpriv。
as_run_user() {
  if is_root && [ "$(id -un)" != "$RUN_USER" ]; then
    setpriv --reuid="$RUN_USER" --regid="$RUN_GROUP" --init-groups -- "$@"
  else
    "$@"
  fi
}

# 把产物属主还给应用用户（只 chown 本次新建的那几个，别对缓存目录做 -R）
own_tree() {
  if is_root; then chown -R "$RUN_USER:$RUN_GROUP" "$@" 2>/dev/null || true; fi
}
own_leaf() {
  if is_root; then chown "$RUN_USER:$RUN_GROUP" "$@" 2>/dev/null || true; fi
}

read_conf() { # $1 = key
  [ -f "$CONF" ] || return 1
  sed -n "s/^$1=//p" "$CONF" | tail -n 1
}

# 读现有 settings.json 的 lan（1/0），读不到就用默认。
current_lan() {
  local v
  v="$(sed -n 's/.*"lan"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p' "$SETTINGS" 2>/dev/null | head -n 1)"
  case "$v" in
    true) printf '1' ;;
    false) printf '0' ;;
    *) printf '%s' "$1" ;;
  esac
}

valid_port() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

normalize_bool() { # true/1/on/yes → 1；false/0/off/no → 0；其它 → 空
  case "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" in
    1|true|on|yes) printf '1' ;;
    0|false|off|no) printf '0' ;;
    *) printf '' ;;
  esac
}

gen_hex32() {
  od -An -tx1 -N32 /dev/urandom 2>/dev/null | tr -d ' \n' | cut -c1-32
}

# ── 收集端口：install 用向导值/默认；config/upgrade 留空则沿用旧值 ─────────────
resolve_port() { # $1=向导变量名 $2=config key $3=默认值
  local val="" saved=""
  if [ "$MODE" = "install" ]; then
    val="${!1:-}"
    [ -n "$val" ] || val="$3"
  else
    val="${!1:-}"
    if [ -z "$val" ]; then
      saved="$(read_conf "$2" || true)"
      [ -n "$saved" ] || saved="$3"
      printf '%s' "$saved"
      return 0
    fi
  fi
  printf '%s' "$val"
}

WIZ_LAN_RAW="${wizard_lan:-}"
LAN="$(normalize_bool "$WIZ_LAN_RAW")"

current_setting_port() {
  sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$SETTINGS" 2>/dev/null | head -n 1
}

case "$MODE" in
  install)
    WEB_PORT="$(resolve_port wizard_port MAGPIE_WEB_PORT "$DEFAULT_WEB_PORT")"
    GATEWAY_PORT="${wizard_gateway_port:-$DEFAULT_GATEWAY_PORT}"
    [ -n "$LAN" ] || LAN=1
    ;;
  *)
    WEB_PORT="$(resolve_port wizard_port MAGPIE_WEB_PORT "$DEFAULT_WEB_PORT")"
    # 网关端口以 magpie 自己的 settings.json 为准（面板里也能改）；向导值只在显式填写时覆盖它。
    if [ -n "${wizard_gateway_port:-}" ]; then
      GATEWAY_PORT="$wizard_gateway_port"
    else
      GATEWAY_PORT="$(current_setting_port)" || true
      [ -n "$GATEWAY_PORT" ] || GATEWAY_PORT="$(read_conf MAGPIE_GATEWAY_PORT || true)"
      [ -n "$GATEWAY_PORT" ] || GATEWAY_PORT="$DEFAULT_GATEWAY_PORT"
    fi
    if [ -z "$LAN" ]; then
      LAN="$(current_lan 1)"
    fi
    ;;
esac

valid_port "$WEB_PORT" || { log "Web 面板端口非法：'$WEB_PORT'"; exit 1; }
valid_port "$GATEWAY_PORT" || { log "网关端口非法：'$GATEWAY_PORT'"; exit 1; }
[ "$WEB_PORT" != "$GATEWAY_PORT" ] || { log "Web 面板端口和网关端口不能相同（都是 $WEB_PORT）"; exit 1; }

# 端口冲突只告警：用户可能想先配好再排障，不该让安装直接失败。
# 占用者是「本应用自己在跑」时不算冲突（改配置时必然处于这种状态）。
port_owner_is_self() { # $1=port
  local line pid exe
  line="$(ss -ltnp 2>/dev/null | grep -E "[:.]$1[[:space:]]" | head -n 1)"
  [ -n "$line" ] || return 1
  pid="$(printf '%s' "$line" | sed -n 's/.*pid=\([0-9]*\).*/\1/p')"
  [ -n "$pid" ] || return 1
  exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null)" || return 1
  [ "$exe" = "$(readlink -f "$BIN" 2>/dev/null)" ]
}
for p in "$WEB_PORT" "$GATEWAY_PORT"; do
  if ss -ltn 2>/dev/null | grep -qE "[:.]$p[[:space:]]" && ! port_owner_is_self "$p"; then
    log "警告：端口 $p 已被占用（$(ss -ltnp 2>/dev/null | grep -E "[:.]$p[[:space:]]" | sed -n 's/.*users:((\(.*\))).*/\1/p' | head -n 1)）"
  fi
done

mkdir -p "$PKGVAR"/{home,config,cache,data,state,tmp} || exit 1

# ── 面板密钥：以包内 app/bin/webkey 为准（构建时写死，见 packaging/build.sh）────
# 飞牛的桌面入口 URL 只认字面量：把 `${wizard_*}` 放进查询串不会被替换（实测请求变成 `/`），
# 所以 key 只能在打包时写进 ui/config 与 bin/webkey；这里把它落到数据目录供进程读取。
valid_web_key() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._~-]{16,64}$'; }

PACKED_KEY_FILE="$APPDEST/bin/webkey"
KEY="$(tr -d '[:space:]' < "$PACKED_KEY_FILE" 2>/dev/null || true)"
valid_web_key "$KEY" || {
  log "安装失败：包内缺少可用的面板密钥 ${PACKED_KEY_FILE}（包不完整，请重新安装）"
  exit 1
}
( umask 077; printf '%s\n' "$KEY" > "$WEB_KEY_FILE" ) || { log "写 $WEB_KEY_FILE 失败"; exit 1; }
chmod 600 "$WEB_KEY_FILE" 2>/dev/null || true
log "面板密钥来自包内 ${PACKED_KEY_FILE}（写入 $WEB_KEY_FILE，0600）"
WEB_KEY="$KEY"

# ── settings.json：只种一次默认值；lan 每次按上面的解析结果更新 ─────────────────
mkdir -p "$XDG_CONFIG/magpie"
PYTHON_BIN=""
for c in /usr/bin/python3 python3; do
  command -v "$c" >/dev/null 2>&1 && { PYTHON_BIN="$c"; break; }
done
if [ -n "$PYTHON_BIN" ]; then
  LAN_BOOL=false; [ "$LAN" = "1" ] && LAN_BOOL=true
  SETTINGS="$SETTINGS" LAN_BOOL="$LAN_BOOL" GW_PORT="$GATEWAY_PORT" "$PYTHON_BIN" - <<'PY' || log "写 settings.json 失败"
import json, os, tempfile
path = os.environ["SETTINGS"]
lan = os.environ["LAN_BOOL"] == "true"
port = int(os.environ["GW_PORT"])
data = {}
if os.path.exists(path):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f) or {}
    except Exception:
        data = {}
seeded = not data
# lan：是否共享到局域网（决定监听 0.0.0.0 还是 127.0.0.1，也决定远端是否强制密钥）
# port：网关端口。上游新版不再从 MAGPIE_ADDR 取端口，settings.json 才是唯一来源。
data["lan"] = lan
data["port"] = port
if seeded:
    # 包管理的应用不跟上游自更新：升级走应用中心，二进制与生命周期脚本必须成套
    data["noAutoUpdate"] = True
    data["noStats"] = True
d = os.path.dirname(path)
fd, tmp = tempfile.mkstemp(dir=d, prefix=".settings-", suffix=".tmp")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PY
else
  if [ ! -f "$SETTINGS" ]; then
    LAN_BOOL=false; [ "$LAN" = "1" ] && LAN_BOOL=true
    ( umask 077; printf '{\n  "lan": %s,\n  "port": %s,\n  "noAutoUpdate": true,\n  "noStats": true\n}\n' \
        "$LAN_BOOL" "$GATEWAY_PORT" > "$SETTINGS" )
    log "没有可用的 python3，已用最小配置写 settings.json"
  else
    log "没有可用的 python3，跳过 settings.json 的 lan/port 更新（请在面板里改「共享到局域网」与网关端口）"
  fi
fi
own_tree "$XDG_CONFIG"

# ── 局域网共享的网关密钥：只在「开启 + 还没有密钥」时创建一次 ──────────────────
if [ "$LAN" = "1" ] && [ ! -s "$GWKEY_FILE" ]; then
  if [ -x "$BIN" ]; then
    OUT="$(as_run_user env \
      HOME="$PKGVAR/home" \
      XDG_CONFIG_HOME="$XDG_CONFIG" \
      XDG_CACHE_HOME="$PKGVAR/cache" \
      XDG_DATA_HOME="$PKGVAR/data" \
      XDG_STATE_HOME="$PKGVAR/state" \
      TMPDIR="$PKGVAR/tmp" \
      MAGPIE_ADDR="127.0.0.1:$GATEWAY_PORT" \
      MAGPIE_NO_STATS=1 \
      "$BIN" gateway-key add "fnOS" 2>&1)"
    GWKEY="$(printf '%s' "$OUT" | grep -o 'sk-magpie-key-[0-9a-f]\{16,\}' | head -n 1)"
    if [ -n "$GWKEY" ]; then
      ( umask 077
        {
          printf '# Magpie 网关密钥（远程客户端用 Authorization: Bearer <key> 访问）\n'
          printf '# 创建时间：%s   名称：fnOS\n' "$(date '+%Y-%m-%d %H:%M:%S')"
          printf 'fnOS\t%s\n' "$GWKEY"
        } > "$GWKEY_FILE" ) || log "写 $GWKEY_FILE 失败"
      chmod 600 "$GWKEY_FILE" 2>/dev/null || true
      log "已生成局域网网关密钥（$GWKEY_FILE，0600）"
    else
      log "生成网关密钥失败：$OUT"
    fi
  else
    log "找不到 $BIN，跳过网关密钥生成"
  fi
fi

# ── config.env（cmd/main 只读这一份）──────────────────────────────────────────
( umask 077
  {
    printf 'MAGPIE_WEB_PORT=%s\n' "$WEB_PORT"
    printf 'MAGPIE_GATEWAY_PORT=%s\n' "$GATEWAY_PORT"
    printf 'MAGPIE_LAN=%s\n' "$LAN"
  } > "$CONF" ) || { log "写 $CONF 失败"; exit 1; }
chmod 600 "$CONF" 2>/dev/null || true

# ── 桌面入口：端口与面板密钥。fnOS 的 ${wizard_port} 只在安装时可用，
#    这里直接写实际值，config/upgrade 后也能跟着变。────────────────────────────
if [ -f "$UI_CONFIG" ] || [ -d "$(dirname "$UI_CONFIG")" ]; then
  cat > "$UI_CONFIG" <<EOF
{
  ".url": {
    "Magpie.main": {
      "title": "Magpie",
      "icon": "images/icon_{0}.png",
      "type": "url",
      "protocol": "http",
      "port": "$WEB_PORT",
      "url": "/?k=$WEB_KEY",
      "allUsers": true
    }
  }
}
EOF
  [ -f "$UI_CONFIG" ] || log "写桌面入口失败（$UI_CONFIG）"
fi

own_leaf "$PKGVAR/home" "$PKGVAR/config" "$PKGVAR/cache" "$PKGVAR/data" "$PKGVAR/state" "$PKGVAR/tmp"
own_leaf "$CONF" "$WEB_KEY_FILE" "${GWKEY_FILE:-/nonexistent}" 2>/dev/null || true
own_leaf "$UI_CONFIG" 2>/dev/null || true
log "配置已写入：面板端口=$WEB_PORT 网关端口=$GATEWAY_PORT 局域网共享=$([ "$LAN" = 1 ] && echo 开 || echo 关)"
exit 0
