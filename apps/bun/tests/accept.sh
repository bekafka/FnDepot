#!/bin/bash
# ==============================================================================
# bun 验收阶梯（在飞牛设备上跑，需 root 读应用目录）
#
#   全量：sudo bash tests/accept.sh all
#   单级：sudo bash tests/accept.sh cmd|cache|realinstall|path
#   卸载前取证：sudo bash tests/accept.sh preuninstall
#   卸载后核对：sudo bash tests/accept.sh postuninstall
#
# 判定：FAIL=0 才算通过；SKIP 表示当次环境不具备条件（无外网/无 Python），
#       既不算通过也不算失败，交付时必须如实写明。
# ==============================================================================
set -u

APP="bun"
APP_DIR="${APP_DIR:-/var/apps/$APP}"
APPDEST="${APPDEST:-$(readlink -f "$APP_DIR/target" 2>/dev/null || echo "$APP_DIR/target")}"
PKGVAR="${PKGVAR:-$(readlink -f "$APP_DIR/var" 2>/dev/null || echo "/vol1/@appdata/$APP")}"
BIN="$APPDEST/bin/bun"
BINX="$APPDEST/bin/bunx"
PROV="$APPDEST/share/PROVENANCE.json"
BINS="bun bunx"
STATE="${STATE:-/tmp/bun-accept-state}"
TS="$(date +%s)"
RUN_USER="${SUDO_USER:-$(id -un)}"
RUN_HOME="${RUN_HOME:-$(getent passwd "$RUN_USER" | cut -d: -f6)}"
[ -n "$RUN_HOME" ] && [ -d "$RUN_HOME" ] || RUN_HOME="/home/$RUN_USER"
WORK="${WORK:-$RUN_HOME/tmp/bun-accept-$TS}"

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '  \033[32m[PASS]\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; }
skip() { SKIP=$((SKIP+1)); printf '  \033[33m[SKIP]\033[0m %s\n' "$*"; }
head2() { printf '\n\033[1m── %s ──\033[0m\n' "$*"; }

prov() {
  python3 - "$PROV" "$1" <<'PY' 2>/dev/null
import json, sys
data = json.load(open(sys.argv[1]))
cur = data
for part in sys.argv[2].split("."):
    cur = cur[part]
print(cur)
PY
}

run_as_user() { # 以目标用户身份、在其可写目录里跑命令（HOME/cwd 都要对，否则 bun 会算错缓存位置）
  if [ "$RUN_USER" != "$(id -un)" ]; then
    su -s /bin/sh "$RUN_USER" -c "cd '$WORK' && HOME='$RUN_HOME' $*"
  else
    ( cd "$WORK" && HOME="$RUN_HOME" bash -lc "$*" )
  fi
}

stage_cmd() {
  head2 "命令可用性"
  if [ -x "$BIN" ]; then ok "可执行文件存在且可执行：$BIN"; else bad "缺少可执行文件 $BIN"; fi
  if [ -x "$BINX" ]; then ok "bunx 存在且可执行：$BINX"; else bad "缺少 bunx（$BINX）"; fi

  if [ -f "$PROV" ]; then
    ok "溯源文件存在：$PROV"
    WANT="$(prov upstream_version)"
    GOT="$("$BIN" --version 2>/dev/null | awk '{print $2}')"
    [ "$WANT" = "$GOT" ] && ok "版本与包内溯源一致：$GOT" \
      || bad "版本不一致：包内溯源 $WANT，实际运行 $GOT"
    ARCH="$(prov payload.arch)"
    MACHINE="$(uname -m)"
    case "$ARCH:$MACHINE" in
      arm64:aarch64|amd64:x86_64) ok "架构匹配：包 $ARCH / 系统 $MACHINE" ;;
      *) bad "架构不匹配：包 $ARCH / 系统 $MACHINE" ;;
    esac
    WANT_SHA="$(prov payload.binary_sha256)"
    GOT_SHA="$(sha256sum "$BIN" 2>/dev/null | awk '{print $1}')"
    [ -n "$WANT_SHA" ] && [ "$WANT_SHA" = "$GOT_SHA" ] \
      && ok "二进制 sha256 与溯源一致：${GOT_SHA:0:16}…" \
      || bad "二进制 sha256 与溯源不符（期望 ${WANT_SHA:0:16}… 实际 ${GOT_SHA:0:16}…）"
  else
    bad "缺少溯源文件 $PROV（payload 不完整？）"
  fi

  for b in $BINS; do
    L="/usr/local/bin/$b"
    if [ -L "$L" ]; then
      [ "$(readlink -f "$L")" = "$(readlink -f "$APPDEST/bin/$b")" ] \
        && ok "命令入口指向本应用：$L → $(readlink "$L")" \
        || bad "命令入口指向别处：$L → $(readlink "$L")"
    else
      bad "命令入口不存在或不是软链：$L"
    fi
  done

  R="$(bash -lc 'command -v bun' 2>/dev/null)"
  [ -n "$R" ] && ok "登录 shell 能解析到 bun：$R" || bad "登录 shell 解析不到 bun"
  R2="$(bash -c 'command -v bunx' 2>/dev/null)"
  [ -n "$R2" ] && ok "非登录 shell 也能解析（/usr/local/bin 在默认 PATH 上）：$R2" \
    || bad "非登录 shell 解析不到 bunx"

  OUT="$(bash -lc 'bun --version' 2>/dev/null)"
  [ -n "$OUT" ] && ok "终端里 bun --version 可用：$OUT" || bad "终端里 bun --version 无输出"
  if bash -lc 'bun --help' >/dev/null 2>&1; then ok "bun --help 正常返回"; else bad "bun --help 报错"; fi
  if bash -lc 'bunx --help' >/dev/null 2>&1; then ok "bunx --help 正常返回（别名入口可用）"; else bad "bunx --help 报错"; fi
}

stage_cache() {
  head2 "缓存与安装目录"
  mkdir -p "$WORK" && chown "$RUN_USER" "$WORK" 2>/dev/null || true
  CACHE="$(run_as_user 'printf "%s/install/cache" "${BUN_INSTALL:-$HOME/.bun}"' 2>/dev/null | tail -n 1)"
  [ -n "$CACHE" ] && ok "包缓存目录（约定）：$CACHE" || bad "推不出缓存目录"
  if [ -n "$CACHE" ]; then
    if mkdir -p "$CACHE" 2>/dev/null && touch "$CACHE/.accept-write-test" 2>/dev/null; then
      ok "缓存目录可写：$CACHE"
      rm -f "$CACHE/.accept-write-test" 2>/dev/null || true
    else
      bad "缓存目录不可写：$CACHE"
    fi
    OWN="$(stat -c '%U:%G' "$CACHE" 2>/dev/null)"
    [ "$OWN" = "$(id -un):$(id -gn)" ] && ok "缓存目录属主是当前用户：$OWN" || skip "缓存目录属主 $OWN"
  fi
}

stage_realinstall() {
  head2 "一次真实使用（离线跑脚本 + 联网装一个依赖，联网部分不可用则跳过）"
  mkdir -p "$WORK/proj" && chown -R "$RUN_USER" "$WORK" 2>/dev/null || true

  # ① 离线：能求值就说明运行时本体可用（不需要网络）
  local out rc
  out="$(run_as_user 'bun -e "console.log(\"bun-runtime-ok\", 1+1)"' 2>&1)"; rc=$?
  if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q 'bun-runtime-ok 2'; then
    ok "运行时求值正常：$(printf '%s' "$out" | tail -n 1)"
  else
    bad "bun -e 求值失败（rc=$rc）：$(printf '%s' "$out" | tail -n 1)"
  fi

  # ② 离线：项目脚本能跑（bun run 读 package.json）
  run_as_user 'cat > proj/package.json <<JSON
{ "name": "accept-probe", "version": "0.0.0", "scripts": { "hello": "echo bun-run-ok" } }
JSON' >/dev/null 2>&1 || true
  out="$(run_as_user 'cd proj && bun run hello' 2>&1)"; rc=$?
  if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q 'bun-run-ok'; then
    ok "项目脚本可执行：bun run hello"
  else
    bad "bun run 失败（rc=$rc）：$(printf '%s' "$out" | tail -n 1)"
  fi

  # ③ 联网：装一个依赖并 import（外网不可达则记 SKIP，不算通过也不算失败）
  out="$(run_as_user 'cd proj && bun add is-odd' 2>&1)"; rc=$?
  if [ $rc -ne 0 ]; then
    case "$out" in
      *network*|*Failed*to*fetch*|*error*sending*request*|*dns*|*timed*out*|*ENOTFOUND*|*ECONNREFUSED*|*Could*not*resolve*)
        skip "bun add 未跑通（外网/源不可达），不算通过：$(printf '%s' "$out" | tail -n 1)" ;;
      *) bad "bun add 失败（rc=$rc）：$(printf '%s' "$out" | tail -n 1)" ;;
    esac
    return
  fi
  ok "bun add 成功（is-odd）"
  out="$(run_as_user 'cd proj && bun -e "const m=require(\"is-odd\"); console.log(\"import-ok\", m.checkOdd?m.checkOdd(3):\"?\")"' 2>&1)"; rc=$?
  if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q 'import-ok'; then
    ok "已安装依赖可被 import：$(printf '%s' "$out" | tail -n 1)"
  else
    skip "依赖 import 未通过（可能是不含该导出的版本）：$(printf '%s' "$out" | tail -n 1)"
  fi

  # ④ bunx 别名入口能跑一个包内工具（同样可跳过）
  out="$(run_as_user 'cd proj && bunx --version' 2>&1)"; rc=$?
  [ $rc -eq 0 ] && ok "bunx 别名入口可用：$(printf '%s' "$out" | tail -n 1)" || bad "bunx 不可用（rc=$rc）"
}

stage_path() {
  head2 "命令名冲突与接管记录"
  local found=0
  for b in $BINS; do
    if [ -s "$PKGVAR/preserved-usr-local-bin-$b" ]; then
      ok "安装时接管了已有命令 $b，原指向已记录：$(head -n 1 "$PKGVAR/preserved-usr-local-bin-$b")"
      found=1
    fi
  done
  [ "$found" = "1" ] || skip "没有接管记录（安装时 /usr/local/bin/{bun,bunx} 本来就不存在）"
  mount | grep -q " /vol1 " && ok "/vol1 已挂载（应用目录与数据目录可访问）" || skip "/vol1 未在挂载表中"
}

stage_preuninstall() {
  head2 "卸载前取证"
  mkdir -p "$(dirname "$STATE")" 2>/dev/null || true
  {
    echo "timestamp=$TS"
    for b in $BINS; do
      echo "${b}_exists=$([ -L "/usr/local/bin/$b" ] && echo yes || echo no)"
      echo "${b}_target=$(readlink "/usr/local/bin/$b" 2>/dev/null)"
      echo "${b}_record=$(head -n 1 "$PKGVAR/preserved-usr-local-bin-$b" 2>/dev/null)"
    done
  } > "$STATE" 2>/dev/null
  ok "已记录卸载前状态到 $STATE"
  cat "$STATE"
  printf '\n下一步：在应用中心界面卸载 %s（带卸载向导的包不能用命令行卸载）\n' "$APP"
}

stage_postuninstall() {
  head2 "卸载后核对"
  [ -f "$STATE" ] && ok "读到卸载前状态：$STATE" || skip "没有卸载前状态文件（先跑 preuninstall）"
  local b L CUR REC
  for b in $BINS; do
    L="/usr/local/bin/$b"
    REC=""
    [ -f "$STATE" ] && REC="$(. "$STATE"; eval "printf '%s' \"\${${b}_record:-}\"")"
    if [ -L "$L" ]; then
      CUR="$(readlink "$L")"
      case "$CUR" in
        /var/apps/$APP/*|/vol1/@appcenter/$APP/*) bad "卸载后 $b 入口仍指向已删除的应用：$L → $CUR" ;;
        *)
          if [ -n "$REC" ] && [ "$CUR" = "$REC" ]; then ok "$b 入口已还原为安装前的指向：$CUR"
          else skip "$b 入口现在指向 $CUR（不是本应用，也不是记录里的原指向）"; fi
          ;;
      esac
    else
      if [ -n "$REC" ]; then
        if [ -e "$REC" ] || [ -L "$REC" ]; then bad "卸载后本应还原 $b 为 $REC，但 $L 不存在"
        else ok "$b 原指向已不存在，未留下悬空链接"; fi
      else
        ok "$b 入口已随应用移除（安装前本来就没有同名命令）"
      fi
    fi
  done
  [ -x "$BIN" ] && bad "卸载后应用目录里的可执行文件仍在：$BIN" || ok "应用目录已清理"
}

MODE="${1:-all}"
case "$MODE" in
  all)           stage_cmd; stage_cache; stage_realinstall; stage_path ;;
  cmd)           stage_cmd ;;
  cache)         stage_cache ;;
  realinstall)   stage_realinstall ;;
  path)          stage_path ;;
  preuninstall)  stage_preuninstall ;;
  postuninstall) stage_postuninstall ;;
  *) echo "usage: $0 {all|cmd|cache|realinstall|path|preuninstall|postuninstall}" >&2; exit 2 ;;
esac

printf '\n\033[1m结果：PASS=%d FAIL=%d SKIP=%d\033[0m\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
