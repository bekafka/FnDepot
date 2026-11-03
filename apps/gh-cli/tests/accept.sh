#!/bin/bash
# ==============================================================================
# gh 验收阶梯（在飞牛设备上跑，需 root 读应用目录）
#
#   全量：sudo bash tests/accept.sh all
#   单级：sudo bash tests/accept.sh cmd|token|api
#   卸载前取证：sudo bash tests/accept.sh preuninstall
#   卸载后核对：sudo bash tests/accept.sh postuninstall
#
# 判定：FAIL=0 才算通过；SKIP = 当次环境不具备条件（例如没有外网、未填 token），
#       既不算通过也不算失败，交付时必须如实写明。
# ==============================================================================
set -u

APP="gh-cli"
APP_DIR="${APP_DIR:-/var/apps/$APP}"
APPDEST="${APPDEST:-$(readlink -f "$APP_DIR/target" 2>/dev/null || echo "$APP_DIR/target")}"
PKGVAR="${PKGVAR:-$(readlink -f "$APP_DIR/var" 2>/dev/null || echo "/vol1/@appdata/$APP")}"
WRAPPER="$APPDEST/bin/gh"
REAL="$APPDEST/bin/gh.real"
LINK="${LINK:-/usr/local/bin/gh}"
PROV="$APPDEST/share/PROVENANCE.json"
TOKEN_MIRROR="$APPDEST/etc/github-token"
STATE="${STATE:-/tmp/gh-accept-state}"
TS="$(date +%s)"
RUN_USER="${SUDO_USER:-$(id -un)}"
RUN_HOME="${RUN_HOME:-$(getent passwd "$RUN_USER" | cut -d: -f6)}"
[ -n "$RUN_HOME" ] && [ -d "$RUN_HOME" ] || RUN_HOME="/home/$RUN_USER"
# 工作目录必须是该用户可写：gh 会在 HOME 下写配置与缓存
WORK="${WORK:-$RUN_HOME/tmp/gh-accept-$TS}"

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '  \033[32m[PASS]\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; }
skip() { SKIP=$((SKIP+1)); printf '  \033[33m[SKIP]\033[0m %s\n' "$*"; }
head2() { printf '\n\033[1m── %s ──\033[0m\n' "$*"; }

prov() {
  python3 - "$PROV" "$1" <<'PY' 2>/dev/null
import json, sys
cur = json.load(open(sys.argv[1]))
for part in sys.argv[2].split("."):
    cur = cur[part]
print(cur)
PY
}

run_as_user() { # 以目标用户身份、在其家目录下跑命令
  # 坑：`su -s /bin/sh <user> -c` 会继承当前 HOME 与 cwd，gh 会把配置写到 /root；
  # 所以显式给 HOME，并先 cd 到该用户可写目录。
  mkdir -p "$WORK" && chown "$RUN_USER" "$WORK" 2>/dev/null || true
  if [ "$RUN_USER" != "$(id -un)" ]; then
    su -s /bin/sh "$RUN_USER" -c "cd '$WORK' && HOME='$RUN_HOME' $*"
  else
    ( cd "$WORK" && HOME="$RUN_HOME" bash -lc "$*" )
  fi
}

stage_cmd() {
  head2 "命令可用性"
  [ -x "$REAL" ]    && ok "真实二进制存在且可执行：$REAL" || bad "缺少 $REAL"
  [ -x "$WRAPPER" ] && ok "命令入口包装存在且可执行：$WRAPPER" || bad "缺少包装 $WRAPPER"

  if [ -f "$PROV" ]; then
    ok "溯源文件存在：$PROV"
    WANT="$(prov upstream_version)"
    GOT_LINE="$("$REAL" --version 2>/dev/null | head -n 1)"
    case "$GOT_LINE" in
      *"$WANT"*) ok "版本与包内溯源一致：$GOT_LINE" ;;
      *) bad "版本不一致：包内溯源 $WANT，实际运行 $GOT_LINE" ;;
    esac
    ARCH="$(prov payload.arch)"; MACHINE="$(uname -m)"
    case "$ARCH:$MACHINE" in
      arm64:aarch64|amd64:x86_64) ok "架构匹配：包 $ARCH / 系统 $MACHINE" ;;
      *) bad "架构不匹配：包 $ARCH / 系统 $MACHINE" ;;
    esac
    WANT_SHA="$(prov payload.binary_sha256)"
    GOT_SHA="$(sha256sum "$REAL" 2>/dev/null | awk '{print $1}')"
    [ -n "$WANT_SHA" ] && [ "$WANT_SHA" = "$GOT_SHA" ] \
      && ok "真实二进制 sha256 与溯源一致：${GOT_SHA:0:16}…" \
      || bad "真实二进制 sha256 与溯源不符（期望 ${WANT_SHA:0:16}… 实际 ${GOT_SHA:0:16}…）"
  else
    bad "缺少溯源文件 $PROV"
  fi

  if [ -L "$LINK" ]; then
    [ "$(readlink -f "$LINK")" = "$(readlink -f "$WRAPPER")" ] \
      && ok "命令入口指向本应用包装层：$LINK → $(readlink "$LINK")" \
      || bad "命令入口指向别处：$LINK → $(readlink "$LINK")"
  else
    bad "命令入口不存在或不是软链：$LINK"
  fi

  RESOLVED="$(bash -lc 'command -v gh' 2>/dev/null)"
  [ -n "$RESOLVED" ] && ok "登录 shell 能解析到 gh：$RESOLVED" || bad "登录 shell 解析不到 gh"
  RESOLVED_NL="$(bash -c 'command -v gh' 2>/dev/null)"
  [ -n "$RESOLVED_NL" ] && ok "非登录 shell 也能解析：$RESOLVED_NL" || bad "非登录 shell 解析不到 gh"

  OUT="$(bash -lc 'gh --version' 2>/dev/null | head -n 1)"
  [ -n "$OUT" ] && ok "终端里 gh --version 可用：$OUT" || bad "终端里 gh --version 无输出"
  bash -lc 'gh --help' >/dev/null 2>&1 && ok "gh --help 正常返回" || bad "gh --help 报错"
}

stage_token() {
  head2 "GitHub Token（向导里填了才有）"
  if [ -s "$TOKEN_MIRROR" ]; then
    ok "终端可读 token 副本存在：$TOKEN_MIRROR（$(stat -c '%a %U:%G' "$TOKEN_MIRROR" 2>/dev/null)）"
    # 以普通用户身份验证注入是否真的生效
    WHO="$(run_as_user "gh api user --jq .login" 2>/dev/null | tr -d '\r\n')"
    if [ -n "$WHO" ]; then
      ok "包装层注入生效，已认证为 @$WHO"
    else
      skip "无法确认 token 是否生效（外网不通或 token 无 user 读取权限）"
    fi
  else
    skip "未找到 token 副本（安装时留空），需要认证时各自 gh auth login"
  fi
  if [ -s "$PKGVAR/github-token" ]; then
    ok "规范来源存在：$PKGVAR/github-token（$(stat -c '%a' "$PKGVAR/github-token" 2>/dev/null)）"
  else
    skip "规范来源不存在（未填 token）"
  fi
}

stage_api() {
  head2 "一次真实 API 调用（需要外网）"
  OUT="$(run_as_user "gh api /repos/cli/cli --jq .full_name" 2>&1)"
  RC=$?
  if [ "$RC" -eq 0 ] && [ "$(printf '%s' "$OUT" | tr -d '\r\n')" = "cli/cli" ]; then
    ok "gh api 调用成功：$OUT"
  else
    case "$OUT" in
      *"could not resolve"*|*"dial tcp"*|*"network"*|*"timeout"*|*"TLS"*|*"404"*|*"401"*)
        skip "API 调用未跑通（网络或认证问题），不算通过：$(printf '%s' "$OUT" | tail -n 1 | cut -c1-120)" ;;
      *) bad "API 调用失败（rc=$RC）：$(printf '%s' "$OUT" | tail -n 1 | cut -c1-120)" ;;
    esac
  fi
}

stage_preuninstall() {
  head2 "卸载前取证"
  mkdir -p "$(dirname "$STATE")" 2>/dev/null || true
  {
    echo "timestamp=$TS"
    echo "link_exists=$([ -L "$LINK" ] && echo yes || echo no)"
    echo "link_target=$(readlink "$LINK" 2>/dev/null)"
    echo "link_resolved=$(readlink -f "$LINK" 2>/dev/null)"
    echo "record=$(head -n 1 "$PKGVAR/preserved-usr-local-bin-gh" 2>/dev/null)"
  } > "$STATE" 2>/dev/null
  ok "已记录卸载前状态到 $STATE"
  cat "$STATE"
  printf '\n下一步：在应用中心界面卸载 %s（带向导，命令行卸载会被要求改用界面）\n' "$APP"
}

stage_postuninstall() {
  head2 "卸载后核对"
  if [ -f "$STATE" ]; then
    ok "读到卸载前状态：$STATE"
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
        else skip "命令入口现在指向 $CUR（不是本应用，也不是记录里的原指向）"; fi
        ;;
    esac
  else
    if [ -n "$REC" ]; then
      if [ -e "$REC" ] || [ -L "$REC" ]; then bad "卸载后本应还原为 $REC，但 $LINK 不存在"
      else ok "原指向已不存在，未留下悬空链接"; fi
    else
      ok "命令入口已随应用移除（安装前本来就没有同名命令）"
    fi
  fi
  [ -x "$REAL" ] && bad "卸载后应用目录里的二进制仍在：$REAL" || ok "应用目录已清理"
}

MODE="${1:-all}"
case "$MODE" in
  all)           stage_cmd; stage_token; stage_api ;;
  cmd)           stage_cmd ;;
  token)         stage_token ;;
  api)           stage_api ;;
  preuninstall)  stage_preuninstall ;;
  postuninstall) stage_postuninstall ;;
  *) echo "usage: $0 {all|cmd|token|api|preuninstall|postuninstall}" >&2; exit 2 ;;
esac

printf '\n\033[1m结果：PASS=%d FAIL=%d SKIP=%d\033[0m\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
