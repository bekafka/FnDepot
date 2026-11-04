#!/bin/bash
# ==============================================================================
# bun · 「把命令挂到 /usr/local/bin」的助手（payload 内，随包安装）
#
#   bun-link.sh ensure   安装/启动阶段：让 /usr/local/bin/{bun,bunx} 指向本应用
#   bun-link.sh remove   卸载阶段：只删指向本应用的链接，并还原被接管的那一份
#   bun-link.sh status   0 = 两条命令都可用；3 = 有缺失
#
# 与 pnpm 包的区别：bun 上游发布包里带**两个**可执行文件（bun 主命令 + bunx 工具运行别名），
# 所以这里按名字逐条记账，而不是单条写死。
#
# 为什么自己挂：平台的 usr-local-linker 在应用**启动时**建链接，而本应用没有常驻进程
# （ctl_stop=false，应用中心不显示启动按钮），「启动」不一定会发生；安装阶段自己挂一次
# 才能保证「装完立刻能敲」。资源声明里仍然写了 usr-local-linker，让平台生命周期也有据可依。
#
# 接管保护：/usr/local/bin/bun、/usr/local/bin/bunx 可能已经被别的安装占着（pipx、手工软链等）。
# 绝不静默覆盖：已存在且指向别处 → 把原指向记进 $PKGVAR/preserved-usr-local-bin-<name>；
# 已是真实文件 → 另存为 .bin 再记路径。remove 时按记录还原，原目标不存在就只清理。
# ==============================================================================
set -u

APPNAME="bun"
BINS="bun bunx"
APPDEST="${TRIM_APPDEST:-/var/apps/$APPNAME/target}"
PKGVAR="${TRIM_PKGVAR:-/vol1/@appdata/$APPNAME}"
LINKDIR="/usr/local/bin"

log() {
  printf '%s - [link] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$PKGVAR/info.log" 2>/dev/null || true
  printf '[link] %s\n' "$1"
}

resolve_path() { readlink -f "$1" 2>/dev/null || printf '%s' "$1"; }

record_of() { printf '%s/preserved-usr-local-bin-%s' "$PKGVAR" "$1"; }
stash_of()  { printf '%s/preserved-usr-local-bin-%s.bin' "$PKGVAR" "$1"; }

points_to_us() { # $1 = bin 名
  local link="$LINKDIR/$1" bin="$APPDEST/bin/$1"
  [ -L "$link" ] || return 1
  [ "$(resolve_path "$link")" = "$(resolve_path "$bin")" ]
}

ensure_link() {
  local bin link rec stash
  for bin in $BINS; do
    link="$LINKDIR/$bin"
    if [ ! -x "$APPDEST/bin/$bin" ]; then
      log "找不到可执行文件 $APPDEST/bin/$bin（payload 缺失？）"
      continue
    fi
    if points_to_us "$bin"; then
      log "$bin 已就绪：$link → $APPDEST/bin/$bin（跳过）"
      continue
    fi
    # 生命周期脚本以包用户身份运行，对 /usr/local/bin 没有写权限；此时交给平台链接机制。
    if [ ! -w "$LINKDIR" ]; then
      log "当前身份（$(id -un)）无 $LINKDIR 写权限：$bin 的命令入口交给平台的 usr-local-linker 建立"
      continue
    fi
    rec="$(record_of "$bin")"; stash="$(stash_of "$bin")"
    mkdir -p "$PKGVAR" 2>/dev/null || true
    if [ -L "$link" ]; then
      printf '%s\n' "$(readlink "$link")" > "$rec" 2>/dev/null || true
      log "接管已有软链：$link → $(readlink "$link")（原指向记录在 $rec）"
      rm -f "$link" 2>/dev/null || true
    elif [ -e "$link" ]; then
      mv -f "$link" "$stash" 2>/dev/null || true
      printf '%s\n' "$stash" > "$rec" 2>/dev/null || true
      log "接管已有文件：$link 已移到 $stash（记录在 $rec）"
    fi
    if ln -sfn "$APPDEST/bin/$bin" "$link" 2>/dev/null; then
      log "已建立命令入口：$link → $APPDEST/bin/$bin"
    else
      log "建立 $link 失败（可执行文件仍在 $APPDEST/bin/$bin）"
    fi
  done
  return 0
}

remove_link() {
  local bin link rec prev
  for bin in $BINS; do
    link="$LINKDIR/$bin"; rec="$(record_of "$bin")"
    if points_to_us "$bin"; then
      rm -f "$link" 2>/dev/null || true
      log "已移除命令入口 $link"
    elif [ -e "$link" ] || [ -L "$link" ]; then
      log "$link 现在不属于本应用（→ $(readlink "$link" 2>/dev/null || echo 文件)），不动它"
    fi
    if [ -s "$rec" ]; then
      prev="$(head -n 1 "$rec" | tr -d '\r\n')"
      if [ -n "$prev" ] && { [ -e "$prev" ] || [ -L "$prev" ]; }; then
        if [ ! -e "$link" ] && [ ! -L "$link" ]; then
          ln -sfn "$prev" "$link" 2>/dev/null && log "已还原被接管的命令入口：$link → $prev"
        else
          log "还原跳过：$link 已被别的东西占用"
        fi
      else
        log "记录里的原指向已不存在（${prev:-空}），不还原，避免留下悬空链接"
      fi
      rm -f "$rec" 2>/dev/null || true
    fi
  done
  return 0
}

status_link() {
  local bin
  for bin in $BINS; do
    points_to_us "$bin" && [ -x "$APPDEST/bin/$bin" ] || return 3
  done
  return 0
}

case "${1:-}" in
  ensure) ensure_link ;;
  remove) remove_link ;;
  status) status_link ;;
  *) echo "usage: $0 {ensure|remove|status}" >&2; exit 2 ;;
esac
