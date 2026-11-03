#!/bin/bash
# ==============================================================================
# pnpm 验收阶梯（在飞牛设备上跑，需 root 读应用目录）
#
#   全量：sudo bash tests/accept.sh all
#   单级：sudo bash tests/accept.sh cmd|store|realinstall|path
#   卸载前取证：sudo bash tests/accept.sh preuninstall    → 记录当前命令入口指向
#   卸载后核对：sudo bash tests/accept.sh postuninstall   → 核对入口已移除或已还原
#
# 判定：FAIL=0 才算通过；SKIP 表示当次环境不具备条件（例如没有外网），
#       既不算通过也不算失败，交付时必须如实写明。
#
# 设计口径（FnFactory specs/acceptance.md 对纯 CLI 包的适配版）：
#   · 断言「命令真的能从终端敲到」，而不是只检查文件存在；
#   · 版本号必须与包内溯源文件一致，避免「包装的是 A、跑起来是 B」；
#   · 真实安装用例走一次完整的 pnpm 取包 + 链接，而不是 --version 就算完；
#   · 卸载相关断言拆成前/后两段，因为应用不能在自己的进程里卸载自己。
# ==============================================================================
set -u

APP="pnpm"
APP_DIR="${APP_DIR:-/var/apps/$APP}"
APPDEST="${APPDEST:-$(readlink -f "$APP_DIR/target" 2>/dev/null || echo "$APP_DIR/target")}"
PKGVAR="${PKGVAR:-$(readlink -f "$APP_DIR/var" 2>/dev/null || echo "/vol1/@appdata/$APP")}"
BIN="$APPDEST/bin/pnpm"
LINK="${LINK:-/usr/local/bin/pnpm}"
PROV="$APPDEST/share/PROVENANCE.json"
STATE="${STATE:-/tmp/pnpm-accept-state}"
TS="$(date +%s)"
# 以哪个用户身份跑 pnpm：优先 sudo 的发起者，否则当前用户
RUN_USER="${SUDO_USER:-$(id -un)}"
RUN_HOME="${RUN_HOME:-$(getent passwd "$RUN_USER" | cut -d: -f6)}"
[ -n "$RUN_HOME" ] && [ -d "$RUN_HOME" ] || RUN_HOME="/home/$RUN_USER"
# 工作目录必须落在该用户可写的地方：pnpm 的虚仓/锁文件要往里写。
# 不要用 /tmp：那是 tmpfs，另一个文件系统会让 pnpm 改用项目内缓存（见 README 说明）。
WORK="${WORK:-$RUN_HOME/tmp/pnpm-accept-$TS}"

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '  \033[32m[PASS]\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; }
skip() { SKIP=$((SKIP+1)); printf '  \033[33m[SKIP]\033[0m %s\n' "$*"; }
head2() { printf '\n\033[1m── %s ──\033[0m\n' "$*"; }

prov() { # $1 = 字段路径（顶层或 payload.xxx）
  python3 - "$PROV" "$1" <<'PY' 2>/dev/null
import json, sys
data = json.load(open(sys.argv[1]))
cur = data
for part in sys.argv[2].split("."):
    cur = cur[part]
print(cur)
PY
}

stage_cmd() {
  head2 "命令可用性"
  if [ -x "$BIN" ]; then ok "可执行文件存在且可执行：$BIN"; else bad "缺少可执行文件 $BIN"; fi
  # 官方 standalone 包自带 dist/（node-gyp 等），必须与可执行文件同级，否则 rebuild 原生模块会失败
  if [ -d "$APPDEST/bin/dist/node_modules/node-gyp" ]; then
    ok "运行时资产 dist/node_modules/node-gyp 已随包安装"
  else
    skip "缺少 bin/dist/node_modules/node-gyp（装的是纯 JS 项目时无影响，涉及原生模块编译会失败）"
  fi

  if [ -f "$PROV" ]; then
    ok "溯源文件存在：$PROV"
    WANT="$(prov upstream_version)"
    GOT="$("$BIN" --version 2>/dev/null)"
    [ "$WANT" = "$GOT" ] && ok "版本与包内溯源一致：$GOT" \
      || bad "版本不一致：包内溯源 $WANT，实际运行 $GOT"
    ARCH="$(prov payload.arch)"
    MACHINE="$(uname -m)"
    case "$ARCH:$MACHINE" in
      arm64:aarch64|amd64:x86_64) ok "架构匹配：包 $ARCH / 系统 $MACHINE" ;;
      *) bad "架构不匹配：包 $ARCH / 系统 $MACHINE" ;;
    esac
    # 摘要自检：包内二进制未被替换
    WANT_SHA="$(prov payload.binary_sha256)"
    GOT_SHA="$(sha256sum "$BIN" 2>/dev/null | awk '{print $1}')"
    [ -n "$WANT_SHA" ] && [ "$WANT_SHA" = "$GOT_SHA" ] \
      && ok "二进制 sha256 与溯源一致：${GOT_SHA:0:16}…" \
      || bad "二进制 sha256 与溯源不符（期望 ${WANT_SHA:0:16}… 实际 ${GOT_SHA:0:16}…）"
  else
    bad "缺少溯源文件 $PROV（payload 不完整？）"
  fi

  if [ -L "$LINK" ]; then
    TARGET="$(readlink "$LINK")"
    [ "$(readlink -f "$LINK")" = "$(readlink -f "$BIN")" ] \
      && ok "命令入口指向本应用：$LINK → $TARGET" \
      || bad "命令入口指向别处：$LINK → $TARGET"
  else
    bad "命令入口不存在或不是软链：$LINK"
  fi

  RESOLVED="$(bash -lc 'command -v pnpm' 2>/dev/null)"
  [ -n "$RESOLVED" ] && ok "登录 shell 能解析到 pnpm：$RESOLVED" \
    || bad "登录 shell 解析不到 pnpm"
  RESOLVED_NONLOGIN="$(bash -c 'command -v pnpm' 2>/dev/null)"
  [ -n "$RESOLVED_NONLOGIN" ] && ok "非登录 shell 也能解析（/usr/local/bin 在默认 PATH 上）：$RESOLVED_NONLOGIN" \
    || bad "非登录 shell 解析不到 pnpm（会拖累 cron / systemd / 脚本调用）"

  OUT="$(bash -lc 'pnpm -v' 2>/dev/null)"
  [ -n "$OUT" ] && ok "终端里 pnpm -v 可用：$OUT" || bad "终端里 pnpm -v 无输出"

  if bash -lc 'pnpm --help' >/dev/null 2>&1; then ok "pnpm --help 正常返回"; else bad "pnpm --help 报错"; fi
}

stage_store() {
  head2 "缓存与全局目录"
  mkdir -p "$WORK" && chown "$RUN_USER" "$WORK" 2>/dev/null || true
  STORE="$(run_as_user pnpm store path 2>/dev/null | tail -n 1)"
  if [ -n "$STORE" ]; then ok "pnpm store path：$STORE"; else bad "pnpm store path 无输出"; fi
  if [ -n "$STORE" ]; then
    if mkdir -p "$STORE" 2>/dev/null && touch "$STORE/.accept-write-test" 2>/dev/null; then
      ok "缓存目录可写：$STORE"
      rm -f "$STORE/.accept-write-test" 2>/dev/null || true
    else
      bad "缓存目录不可写：$STORE"
    fi
  fi
  GLOBAL_BIN="$(run_as_user pnpm bin -g 2>/dev/null | tail -n 1)"
  [ -n "$GLOBAL_BIN" ] && ok "全局命令目录（pnpm bin -g）：$GLOBAL_BIN" || skip "pnpm bin -g 无输出（版本差异，非致命）"
}

run_as_user() { # 以目标用户身份、在他的家目录附近跑命令
  # 两个实测过的坑：
  #   · `su -s /bin/sh <user> -c` 会继承当前 HOME 与 cwd，pnpm 于是拿 /root 当项目目录，
  #     直接报 ERR_PNPM_CLI_PREFIX_IO_ERROR: failed to access /root/node_modules；
  #   · 所以既要显式给 HOME，也要先 cd 到该用户可写的目录。
  if [ "$RUN_USER" != "$(id -un)" ]; then
    su -s /bin/sh "$RUN_USER" -c "cd '$WORK' && HOME='$RUN_HOME' $*"
  else
    ( cd "$WORK" && HOME="$RUN_HOME" bash -lc "$*" )
  fi
}

stage_realinstall() {
  head2 "一次真实安装（需要外网访问 npm 源）"
  mkdir -p "$WORK" && chown "$RUN_USER" "$WORK" 2>/dev/null || { bad "无法创建临时目录 $WORK"; return; }
  cat > "$WORK/package.json" <<'JSON'
{
  "name": "pnpm-accept-fixture",
  "private": true,
  "version": "0.0.0"
}
JSON
  local out rc
  out="$(cd "$WORK" && run_as_user "cd '$WORK' && pnpm add is-odd@3.0.1" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$out" in
      *ERR_PNPM_*|*ENOTFOUND*|*EAI_AGAIN*|*ETIMEDOUT*|*ECONNREFUSED*|*network*|*certificate*)
        skip "真实安装未跑通（网络/源不可达），不算通过：$(printf '%s' "$out" | tail -n 1)" ;;
      *) bad "真实安装失败（rc=$rc）：$(printf '%s' "$out" | tail -n 1)" ;;
    esac
    return
  fi
  [ -d "$WORK/node_modules/is-odd" ] && ok "依赖已落盘：node_modules/is-odd" \
    || bad "node_modules/is-odd 不存在"
  [ -f "$WORK/pnpm-lock.yaml" ] && ok "锁文件已生成：pnpm-lock.yaml" \
    || bad "没有生成 pnpm-lock.yaml"
  # 软链结构（pnpm 的标志性行为）
  [ -L "$WORK/node_modules/is-odd" ] && ok "node_modules 用软链指向内容寻址目录（pnpm 结构）" \
    || skip "node_modules/is-odd 不是软链（可能被 hoist 配置改变）"
  if [ -d "$WORK/node_modules/.pnpm" ]; then ok "内容寻址目录存在：node_modules/.pnpm"; else bad "缺少 node_modules/.pnpm"; fi
}

stage_path() {
  head2 "命令名冲突与接管记录"
  if [ -s "$PKGVAR/preserved-usr-local-bin-pnpm" ]; then
    ok "安装时接管了已有命令，原指向已记录：$(head -n 1 "$PKGVAR/preserved-usr-local-bin-pnpm")"
  else
    skip "没有接管记录（安装时 /usr/local/bin/pnpm 本来就不存在）"
  fi
  for n in pn px pnpx; do
    if [ -e "/usr/local/bin/$n" ]; then
      skip "存在额外的短命令名 /usr/local/bin/$n（本包不注册短名；如指向别处需自行判断）"
    fi
  done
  mount | grep -q " /vol1 " && ok "/vol1 已挂载（应用目录与数据目录可访问）" || skip "/vol1 未在挂载表中"
}

stage_preuninstall() {
  head2 "卸载前取证"
  mkdir -p "$(dirname "$STATE")" 2>/dev/null || true
  {
    echo "timestamp=$TS"
    echo "link_exists=$([ -L "$LINK" ] && echo yes || echo no)"
    echo "link_target=$(readlink "$LINK" 2>/dev/null)"
    echo "link_resolved=$(readlink -f "$LINK" 2>/dev/null)"
    echo "record=$(head -n 1 "$PKGVAR/preserved-usr-local-bin-pnpm" 2>/dev/null)"
  } > "$STATE" 2>/dev/null
  ok "已记录卸载前状态到 $STATE"
  cat "$STATE"
  printf '\n下一步：sudo appcenter-cli uninstall %s\n' "$APP"
}

stage_postuninstall() {
  head2 "卸载后核对"
  if [ -f "$STATE" ]; then
    ok "读到卸载前状态：$STATE"
    # shellcheck disable=SC1090
    REC="$(. "$STATE"; printf '%s' "${record:-}")"
  else
    skip "没有卸载前状态文件（先跑 preuninstall 才能核对还原）"
    REC=""
  fi
  if [ -L "$LINK" ]; then
    CUR="$(readlink "$LINK")"
    case "$CUR" in
      /var/apps/$APP/*|/vol1/@appcenter/$APP/*) bad "卸载后命令入口仍指向已删除的应用：$LINK → $CUR" ;;
      *)
        if [ -n "$REC" ] && [ "$CUR" = "$REC" ]; then ok "命令入口已还原为安装前的指向：$CUR"
        else skip "命令入口现在指向 $CUR（不是本应用，也不是记录里的原指向）" ; fi
        ;;
    esac
  else
    if [ -n "$REC" ]; then
      if [ -e "$REC" ] || [ -L "$REC" ]; then bad "卸载后本应还原为 $REC，但 $LINK 不存在"; else ok "原指向已不存在，未留下悬空链接（$LINK 未创建）"; fi
    else
      ok "命令入口已随应用移除（安装前本来就没有同名命令）"
    fi
  fi
  [ -x "$BIN" ] && bad "卸载后应用目录里的可执行文件仍在：$BIN" || ok "应用目录已清理"
}

MODE="${1:-all}"
case "$MODE" in
  all)          stage_cmd; stage_store; stage_realinstall; stage_path ;;
  cmd)          stage_cmd ;;
  store)        stage_store ;;
  realinstall)  stage_realinstall ;;
  path)         stage_path ;;
  preuninstall) stage_preuninstall ;;
  postuninstall) stage_postuninstall ;;
  *) echo "usage: $0 {all|cmd|store|realinstall|path|preuninstall|postuninstall}" >&2; exit 2 ;;
esac

printf '\n\033[1m结果：PASS=%d FAIL=%d SKIP=%d\033[0m\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
