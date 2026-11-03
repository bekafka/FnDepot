#!/bin/bash
# ==============================================================================
# PhotoCraft · 向导值 → 运行时配置（install_callback / config_callback / upgrade_callback 共用）
#
#   用法：apply-config.sh <install|config|upgrade>
#
# 要点：
#   · 应用中心不会把向导值传给 cmd/main（官方契约），所以在这里转存成
#     ${TRIM_PKGVAR}/config.env，cmd/main 启动时 source 它。
#   · 端口/监听非法时显式失败，不静默回落；config/upgrade 模式「留空 = 保持当前值」。
#   · 桌面入口 app/ui/config 里写「实际端口」而不是 ${wizard_port}：飞牛的入口占位符
#     只在安装时可用，设置页改端口后必须同步重写，否则点图标会打到旧端口。
# ==============================================================================
set -u

MODE="${1:-install}"
APPNAME="PhotoCraft"
PKGVAR="${TRIM_PKGVAR:?TRIM_PKGVAR is required}"
APPDEST="${TRIM_APPDEST:?TRIM_APPDEST is required}"

CONF="$PKGVAR/config.env"
LOG="$PKGVAR/info.log"
UI_CONFIG="$APPDEST/ui/config"

DEFAULT_PORT=28200
DEFAULT_LISTEN="0.0.0.0"

log() {
  printf '%s - [config:%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$MODE" "$*" >> "$LOG" 2>/dev/null || true
  if [ -n "${TRIM_TEMP_LOGFILE:-}" ]; then
    printf '%s - [config:%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$MODE" "$*" >> "$TRIM_TEMP_LOGFILE" 2>/dev/null || true
  fi
}

read_conf() { [ -f "$CONF" ] || return 1; sed -n "s/^$1=//p" "$CONF" | tail -n 1; }
valid_port() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
normalize_host() {
  case "$(printf '%s' "$1" | tr -d '[:space:]')" in
    0.0.0.0|*|any) printf '0.0.0.0' ;;
    127.0.0.1|localhost) printf '127.0.0.1' ;;
    *) return 1 ;;
  esac
}

if [ "$MODE" = "install" ]; then
  PORT="${wizard_port:-}"
  [ -n "$PORT" ] || PORT="$DEFAULT_PORT"
else
  PORT="${wizard_port:-}"
  if [ -z "$PORT" ]; then
    PORT="$(read_conf PHOTOCRAFT_PORT || true)"
    [ -n "$PORT" ] || PORT="$DEFAULT_PORT"
  fi
fi
valid_port "$PORT" || { log "端口非法：'$PORT'（必须是 1-65535 的数字）"; exit 1; }

WIZ_HOST="${wizard_host:-}"
if [ "$MODE" = "install" ]; then
  HOST="$(normalize_host "${WIZ_HOST:-$DEFAULT_LISTEN}")" || { log "监听范围非法：'$WIZ_HOST'"; exit 1; }
else
  case "$WIZ_HOST" in
    ''|keep|KEEP) HOST="$(read_conf PHOTOCRAFT_LISTEN || true)"; [ -n "$HOST" ] || HOST="$DEFAULT_LISTEN" ;;
    *) HOST="$(normalize_host "$WIZ_HOST")" || { log "监听范围非法：'$WIZ_HOST'"; exit 1; } ;;
  esac
fi

mkdir -p "$PKGVAR/home" "$PKGVAR/tmp" || { log "创建数据目录失败"; exit 1; }

( umask 022
  {
    printf 'PHOTOCRAFT_PORT=%s\n' "$PORT"
    printf 'PHOTOCRAFT_LISTEN=%s\n' "$HOST"
  } > "$CONF" ) || { log "写 $CONF 失败"; exit 1; }
chmod 0644 "$CONF" 2>/dev/null || true

if ss -ltn 2>/dev/null | grep -qE "[:.]$PORT[[:space:]]"; then
  OWNER="$(ss -ltnp 2>/dev/null | grep -E "[:.]$PORT[[:space:]]" | sed -n 's/.*users:((\(.*\))).*/\1/p' | head -n 1)"
  case "$OWNER" in
    *photocraft-web*) : ;;
    *) log "警告：端口 $PORT 已被占用（${OWNER:-未知进程}）" ;;
  esac
fi

# 桌面入口：写实际端口
if [ -d "$(dirname "$UI_CONFIG")" ]; then
  cat > "$UI_CONFIG" <<EOF
{
  ".url": {
    "PhotoCraft.main": {
      "title": "PhotoCraft",
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

log "配置已写入：端口=$PORT 监听=$HOST"
exit 0
