#!/bin/bash
# ==============================================================================
# CloudflareIP · 向导值 → 运行时配置（install_callback / config_callback / upgrade_callback 共用）
#
#   用法：apply-config.sh <install|config|upgrade>
#
# 设计要点：
#   · 应用中心不会把向导值传给 cmd/main（官方契约），所以在这里转存成
#     ${TRIM_PKGVAR}/config.env，cmd/main 启动时 source 它。
#   · 端口/监听地址非法时显式失败，不静默回落默认值；config/upgrade 模式下
#     「留空 = 保持当前值」，应用设置页误保存不会把端口改回去。
#   · 工具自己的配置在 ${TRIM_PKGVAR}/config/config.json（域名列表、探测参数由面板维护），
#     只在文件不存在时种一份默认值，之后一字不改，避免覆盖用户配置。
#   · 桌面入口 app/ui/config 里写「实际端口」而不是 ${wizard_port}：飞牛的入口占位符
#     只在安装时可用，设置页改端口后必须同步重写，否则点图标会 404。
# ==============================================================================
set -u

MODE="${1:-install}"
APPNAME="CloudflareIP"
PKGVAR="${TRIM_PKGVAR:?TRIM_PKGVAR is required}"
APPDEST="${TRIM_APPDEST:?TRIM_APPDEST is required}"

CONF="$PKGVAR/config.env"
LOG="$PKGVAR/info.log"
CONFIG_DIR="$PKGVAR/config"
CONFIG_JSON="$CONFIG_DIR/config.json"
UI_CONFIG="$APPDEST/ui/config"

DEFAULT_PORT=26890
DEFAULT_LISTEN="0.0.0.0"

log() {
  printf '%s - [config:%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$MODE" "$*" >> "$LOG" 2>/dev/null || true
  if [ -n "${TRIM_TEMP_LOGFILE:-}" ]; then
    printf '%s - [config:%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$MODE" "$*" >> "$TRIM_TEMP_LOGFILE" 2>/dev/null || true
  fi
}

read_conf() { # $1 = key
  [ -f "$CONF" ] || return 1
  sed -n "s/^$1=//p" "$CONF" | tail -n 1
}

valid_port() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

normalize_host() { # 只接受两种意图明确的取值；其余视为非法
  case "$(printf '%s' "$1" | tr -d '[:space:]')" in
    0.0.0.0|*|any) printf '0.0.0.0' ;;
    127.0.0.1|localhost) printf '127.0.0.1' ;;
    *) return 1 ;;
  esac
}

# ── 端口：install 用向导值/默认；config/upgrade 留空则沿用旧值 ────────────────
if [ "$MODE" = "install" ]; then
  PORT="${wizard_port:-}"
  [ -n "$PORT" ] || PORT="$DEFAULT_PORT"
else
  PORT="${wizard_port:-}"
  if [ -z "$PORT" ]; then
    PORT="$(read_conf CFIP_PORT || true)"
    [ -n "$PORT" ] || PORT="$DEFAULT_PORT"
  fi
fi
valid_port "$PORT" || { log "端口非法：'$PORT'（必须是 1-65535 的数字）"; exit 1; }

# ── 监听范围 ────────────────────────────────────────────────────────────────
WIZ_HOST="${wizard_host:-}"
if [ "$MODE" = "install" ]; then
  HOST="$(normalize_host "${WIZ_HOST:-$DEFAULT_LISTEN}")" || { log "监听范围非法：'$WIZ_HOST'"; exit 1; }
else
  case "$WIZ_HOST" in
    ''|keep|KEEP) HOST="$(read_conf CFIP_LISTEN || true)"; [ -n "$HOST" ] || HOST="$DEFAULT_LISTEN" ;;
    *) HOST="$(normalize_host "$WIZ_HOST")" || { log "监听范围非法：'$WIZ_HOST'"; exit 1; } ;;
  esac
fi

# ── 写 hosts 的开关（默认允许；关掉 = 只能测速预览）──────────────────────────
WIZ_WRITE="${wizard_allow_write:-}"
if [ "$MODE" = "install" ]; then
  case "$WIZ_WRITE" in
    0|no|off|false) WRITE=0 ;;
    *) WRITE=1 ;;
  esac
else
  case "$WIZ_WRITE" in
    0|no|off|false) WRITE=0 ;;
    1|yes|on|true) WRITE=1 ;;
    *) WRITE="$(read_conf CFIP_WRITE || true)"; case "$WRITE" in 0|1) ;; *) WRITE=1 ;; esac ;;
  esac
fi

# ── 目录 ────────────────────────────────────────────────────────────────────
mkdir -p "$CONFIG_DIR" "$PKGVAR/home" "$PKGVAR/tmp" || { log "创建数据目录失败"; exit 1; }

# ── config.env（cmd/main 只读这一份）────────────────────────────────────────
( umask 022
  {
    printf 'CFIP_PORT=%s\n' "$PORT"
    printf 'CFIP_LISTEN=%s\n' "$HOST"
    printf 'CFIP_WRITE=%s\n' "$WRITE"
  } > "$CONF" ) || { log "写 $CONF 失败"; exit 1; }
chmod 0644 "$CONF" 2>/dev/null || true

# ── config.json：只在不存在时种默认值，之后不覆盖用户配置 ────────────────────
HOSTS_PATH="${wizard_hosts_path:-/etc/hosts}"
case "$HOSTS_PATH" in
  /etc/hosts|/etc/hosts.*) ;;
  *) log "hosts 路径非法：'$HOSTS_PATH'（只接受 /etc/hosts 形式），改用 /etc/hosts"; HOSTS_PATH="/etc/hosts" ;;
esac
if [ ! -s "$CONFIG_JSON" ]; then
  ( umask 022
    cat > "$CONFIG_JSON" <<EOF
{
  "domains": [],
  "hosts_path": "$HOSTS_PATH",
  "probe_path": "/cdn-cgi/trace",
  "page_path": "/",
  "listen": "$HOST:$PORT",
  "candidates_per_range": 8,
  "conc": 64,
  "timeout_s": 5,
  "top_n": 6,
  "repeat": 3,
  "ips_per_domain": 3
}
EOF
  ) || { log "写 $CONFIG_JSON 失败"; exit 1; }
  log "已生成 $CONFIG_JSON（目标 hosts：$HOSTS_PATH）"
else
  log "$CONFIG_JSON 已存在，保留用户配置（监听地址由启动参数覆盖）"
fi
chmod 0644 "$CONFIG_JSON" 2>/dev/null || true

# 端口冲突只告警：用户可能先配好再排障，不该让安装直接失败。
if ss -ltn 2>/dev/null | grep -qE "[:.]$PORT[[:space:]]"; then
  OWNER="$(ss -ltnp 2>/dev/null | grep -E "[:.]$PORT[[:space:]]" | sed -n 's/.*users:((\(.*\))).*/\1/p' | head -n 1)"
  case "$OWNER" in
    *cloudflareip*) : ;;
    *) log "警告：端口 $PORT 已被占用（${OWNER:-未知进程}）" ;;
  esac
fi

# ── 桌面入口：写实际端口（不用 ${wizard_port}，设置页改端口后也跟得上）────────
if [ -d "$(dirname "$UI_CONFIG")" ]; then
  cat > "$UI_CONFIG" <<EOF
{
  ".url": {
    "CloudflareIP.main": {
      "title": "Cloudflare 优选",
      "icon": "images/icon_{0}.png",
      "type": "url",
      "protocol": "http",
      "port": "$PORT",
      "url": "/",
      "allUsers": true
    }
  }
}
EOF
  chmod 0644 "$UI_CONFIG" 2>/dev/null || true
fi

log "配置已写入：端口=$PORT 监听=$HOST 写hosts=$([ "$WRITE" = 1 ] && echo 允许 || echo 预览)"
exit 0
