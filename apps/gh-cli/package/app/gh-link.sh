#!/bin/bash
# ==============================================================================
# gh · 「把命令挂到 /usr/local/bin」的助手（payload 内，随包安装）
#
#   gh-link.sh ensure   安装/启动阶段调用：让 /usr/local/bin/gh 指向本应用
#   gh-link.sh remove   卸载阶段调用：只删指向本应用的链接，并还原被接管的那一份
#   gh-link.sh status   0 = 命令可用；3 = 不可用
#
# 为什么自己挂、而不是只靠 manifest 里的 usr-local-linker：
#   平台的 usr-local-linker 在**应用启动时**建链接、停止时移除；本应用没有常驻
#   进程（ctl_stop=false，应用中心不显示启动按钮），因此「启动」这一步不一定会发生。
#   安装阶段（install_callback，root 身份）自己挂一次，才能保证「装完立刻能敲 gh」。
#   资源声明仍然保留，让平台在它自己的生命周期里也有据可依。
#
# 接管保护：
#   /usr/local/bin/gh 这类**通用命令名**在机器上可能已经有人占着（另一套 gh、
#   手工软链、npm 全局安装等）。这里绝不静默覆盖：
#     · 已存在且指向别处 → 把原指向写进 $PKGVAR/preserved-usr-local-bin-gh 再改指；
#     · 已存在且是真实文件（不是软链） → 同上，另存一份原文件后的路径记录；
#     · 已经是本应用 → 幂等，什么都不做。
#   remove 时按记录还原；原目标早已不存在就只清理，不制造新的悬空链接。
# ==============================================================================
set -u

APPNAME="gh"
APPDEST="${TRIM_APPDEST:-/var/apps/$APPNAME/target}"
PKGVAR="${TRIM_PKGVAR:-/vol1/@appdata/$APPNAME}"
BIN="$APPDEST/bin/gh"
LINK="/usr/local/bin/gh"
RECORD="$PKGVAR/preserved-usr-local-bin-gh"
STASH="$PKGVAR/preserved-usr-local-bin-gh.bin"

log() {
  printf '%s - [link] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$PKGVAR/info.log" 2>/dev/null || true
  printf '[link] %s\n' "$1"
}

resolve_path() { readlink -f "$1" 2>/dev/null || printf '%s' "$1"; }

points_to_us() {
  [ -L "$LINK" ] || return 1
  [ "$(resolve_path "$LINK")" = "$(resolve_path "$BIN")" ]
}

ensure_link() {
  if [ ! -x "$BIN" ]; then
    log "找不到可执行文件 $BIN（payload 缺失？）"
    return 1
  fi
  mkdir -p "$PKGVAR" 2>/dev/null || true

  if points_to_us; then
    log "命令已就绪：$LINK → $BIN（跳过）"
    return 0
  fi

  # 生命周期脚本默认以包用户（run-as=package）运行，对 /usr/local/bin 没有写权限。
  # 这不是失败：manifest 里声明了 usr-local-linker，平台会在安装/启动时自己建立链接
  # （本机实测：装完 /usr/local/bin/gh 已存在并指向 /var/apps/gh/target/bin/gh）。
  # 只有在脚本以 root 跑（例如 privilege 改成 run-as=root）时，下面这套接管逻辑才会生效。
  if [ ! -w "$(dirname "$LINK")" ]; then
    log "当前身份（$(id -un)）无 $(dirname "$LINK") 写权限：命令入口交给平台的 usr-local-linker 建立"
    return 0
  fi

  # 路径已被别人占用：先记账，再接管。真实文件另外留一份，避免对方彻底消失。
  if [ -e "$LINK" ] || [ -L "$LINK" ]; then
    if [ -L "$LINK" ]; then
      printf '%s\n' "$(readlink "$LINK")" > "$RECORD" 2>/dev/null || true
      log "接管已有软链：$LINK → $(readlink "$LINK")（原指向已记录到 $RECORD）"
    else
      mv -f "$LINK" "$STASH" 2>/dev/null || true
      printf '%s\n' "$STASH" > "$RECORD" 2>/dev/null || true
      log "接管已有文件：$LINK 已移到 $STASH（记录在 $RECORD）"
    fi
    rm -f "$LINK" 2>/dev/null || true
  fi

  if [ ! -d "$(dirname "$LINK")" ]; then
    log "目录 $(dirname "$LINK") 不存在，跳过链接（可执行文件仍在 $BIN）"
    return 1
  fi
  if ln -sfn "$BIN" "$LINK" 2>/dev/null; then
    log "已建立命令入口：$LINK → $BIN"
    return 0
  fi
  log "建立 $LINK 失败（权限不足？可执行文件仍在 $BIN）"
  return 1
}

remove_link() {
  if points_to_us; then
    rm -f "$LINK" 2>/dev/null || true
    log "已移除命令入口 $LINK"
  elif [ -e "$LINK" ] || [ -L "$LINK" ]; then
    log "$LINK 现在不属于本应用（→ $(readlink "$LINK" 2>/dev/null || echo 文件)），不动它"
  fi

  if [ -s "$RECORD" ]; then
    local prev
    prev="$(head -n 1 "$RECORD" | tr -d '\r\n')"
    if [ -n "$prev" ] && { [ -e "$prev" ] || [ -L "$prev" ]; }; then
      if [ ! -e "$LINK" ] && [ ! -L "$LINK" ]; then
        ln -sfn "$prev" "$LINK" 2>/dev/null && log "已还原被接管的命令入口：$LINK → $prev"
      else
        log "还原跳过：$LINK 已被别的东西占用"
      fi
    else
      log "记录里的原指向已不存在（${prev:-空}），不还原，避免留下悬空链接"
    fi
    rm -f "$RECORD" 2>/dev/null || true
  fi
  return 0
}

status_link() {
  points_to_us && [ -x "$BIN" ] && return 0
  return 3
}

case "${1:-}" in
  ensure) ensure_link ;;
  remove) remove_link ;;
  status) status_link ;;
  *) echo "usage: $0 {ensure|remove|status}" >&2; exit 2 ;;
esac
