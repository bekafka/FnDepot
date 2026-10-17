#!/bin/bash
# ==============================================================================
# Motrix · 向导值 → 配置文件（install_callback 与 config_callback 共用）
#
#   用法：apply-config.sh <install|config>
#
# 设计要点：
#   · 向导值一律当不可信字符串，用前重新校验；非法值显式失败，不静默用默认。
#   · 字段留空 = 保持当前值（首次安装时用默认值），这样"应用设置"页误保存不会把
#     端口重置回 26800。
#   · 不接管登录口令：口令一律由 Motrix 首次启动时自动生成到
#     ${MOTRIX_DATA_DIR}/operator-token（0600），本脚本不读、不写、不落任何口令。
#   · 端口/路径只落 ${TRIM_PKGVAR}/config.env，由 cmd/main 读取 —— App Center 不会
#     把向导值传给 cmd/main，这是官方契约，必须自己转存。
# ==============================================================================
set -u

MODE="${1:-install}"
APPNAME="Motrix"
PKGVAR="${TRIM_PKGVAR:?TRIM_PKGVAR is required}"
APPDEST="${TRIM_APPDEST:?TRIM_APPDEST is required}"
SHARE_LIST="${TRIM_DATA_SHARE_PATHS:-}"
RUN_USER="${TRIM_USERNAME:-$APPNAME}"
RUN_GROUP="${TRIM_GROUPNAME:-$APPNAME}"
CONF="$PKGVAR/config.env"
LOG="$PKGVAR/info.log"
DATA_DIR="$PKGVAR/data"

log() { printf '%s - [config] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

is_root() { [ "$(id -u)" = "0" ]; }

as_run_user() { # 以应用身份执行，尽量少用 root
  if is_root; then runuser -u "$RUN_USER" -- "$@"; else "$@"; fi
}

own() { # 把产物属主还给应用用户（install_callback 可能是 root）
  if is_root; then chown "$RUN_USER:$RUN_GROUP" "$@" 2>/dev/null || true; fi
}

read_conf() { # $1 = key
  [ -f "$CONF" ] || return 1
  sed -n "s/^$1=//p" "$CONF" | tail -n 1
}

resolve() { # $1=向导变量名 $2=config key $3=默认值
  local wizard_value="${!1:-}"
  if [ -n "$wizard_value" ]; then printf '%s' "$wizard_value"; return 0; fi
  local saved
  saved="$(read_conf "$2" || true)"
  if [ -n "$saved" ]; then printf '%s' "$saved"; return 0; fi
  printf '%s' "$3"
}

valid_port() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

# ── 收集 ───────────────────────────────────────────────────────────────────────
PORT="$(resolve wizard_port MOTRIX_PORT 26800)"
MDXP_PORT="$(resolve wizard_mdxp_port MOTRIX_MDXP_PORT 16801)"
ALLOW_EXTENSION="$(resolve wizard_allow_extension MOTRIX_ALLOW_EXTENSION false)"
EXTRA_DIRS="$(resolve wizard_extra_save_dirs MOTRIX_EXTRA_SAVE_DIRS '')"

valid_port "$PORT" || { log "非法端口 wizard_port=$PORT"; exit 1; }
if [ "$MDXP_PORT" != "0" ]; then
  valid_port "$MDXP_PORT" || { log "非法端口 wizard_mdxp_port=$MDXP_PORT"; exit 1; }
fi
[ "$PORT" != "$MDXP_PORT" ] || { log "Web 端口与 MDXP 端口相同（$PORT），拒绝"; exit 1; }
case "$ALLOW_EXTENSION" in true|false) ;; *) log "wizard_allow_extension 非法：$ALLOW_EXTENSION"; exit 1 ;; esac

# 端口占用只告警不阻断：占用者可能是别的应用（不该由我们的安装脚本判断对错），
# 但把占用者的名字写进日志，用户一眼就知道该换哪个端口。
port_owner() {
  ss -ltnp 2>/dev/null | grep -E "[:.]$1[[:space:]]" \
    | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -n 1
}
for check_port in "$PORT" "$MDXP_PORT"; do
  [ "$check_port" = "0" ] && continue
  owner="$(port_owner "$check_port")"
  [ -n "$owner" ] && log "警告：端口 $check_port 已被占用（$owner），应用启动会失败，请换一个端口"
done

# ── 下载目录 ───────────────────────────────────────────────────────────────────
SHARE_ROOT="${SHARE_LIST%%:*}"
[ -n "$SHARE_ROOT" ] || SHARE_ROOT="$PKGVAR/share"
DEFAULT_SAVE="$SHARE_ROOT/downloads"
mkdir -p "$DEFAULT_SAVE" 2>/dev/null || true
own "$DEFAULT_SAVE" || true

can_write() {
  if is_root; then runuser -u "$RUN_USER" -- test -w "$1" 2>/dev/null; else test -w "$1"; fi
}

ALLOWED="$DEFAULT_SAVE"
if [ -n "$EXTRA_DIRS" ]; then
  IFS=':' read -r -a parts <<< "$EXTRA_DIRS"
  for dir in "${parts[@]}"; do
    [ -n "$dir" ] || continue
    case "$dir" in
      /*) ;;
      *) log "忽略非绝对路径的额外下载目录：$dir"; continue ;;
    esac
    if [ -d "$dir" ] && can_write "$dir"; then
      ALLOWED="$ALLOWED:$dir"
    else
      log "忽略不可写的额外下载目录（$RUN_USER 无写权限）：$dir"
    fi
  done
fi

# ── 落盘 ───────────────────────────────────────────────────────────────────────
umask 022
mkdir -p "$PKGVAR" "$DATA_DIR"
{
  printf 'MOTRIX_PORT=%s\n' "$PORT"
  printf 'MOTRIX_MDXP_PORT=%s\n' "$MDXP_PORT"
  printf 'MOTRIX_ALLOW_EXTENSION=%s\n' "$ALLOW_EXTENSION"
  printf 'MOTRIX_DEFAULT_SAVE_DIR=%s\n' "$DEFAULT_SAVE"
  printf 'MOTRIX_ALLOWED_SAVE_DIRS=%s\n' "$ALLOWED"
} > "$CONF"
own "$CONF"

log "配置已写入：port=$PORT mdxp=$MDXP_PORT allow_extension=$ALLOW_EXTENSION allowed_save_dirs=$ALLOWED"
