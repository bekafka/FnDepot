#!/bin/bash
# ==============================================================================
# gh · 命令入口包装（随包安装为 bin/gh，真正的二进制是同级 gh.real）
#
# 作用只有一个：把安装向导里填的 GitHub Token 以 GH_TOKEN 的形式注入，
# 让终端里任何用户执行 gh 时都是已认证状态，不必各自再跑 gh auth login。
#
# 取值优先级（与 gh 自身一致，我们不覆盖用户已有设置）：
#   1. 环境里已经有 GH_TOKEN / GITHUB_TOKEN → 原样透传，什么都不做
#   2. 应用目录里的 token 文件（安装时由 install_callback 写入）：
#        首选 /var/apps/gh-cli/target/etc/github-token（0640 + ACL 授予设备普通用户组读）
#        备选 /var/apps/gh-cli/var/github-token（0600，仅应用账号可读）
#   3. 都没有 → 直接执行 gh，需要认证时它会照常提示
#
# 可用 GH_FNOS_TOKEN_FILE 指定别的路径；GH_FNOS_BIN 指定真实二进制（排障用）。
# ==============================================================================
set -u

REAL="${GH_FNOS_BIN:-/var/apps/gh-cli/target/bin/gh.real}"
TOKEN_FILE="${GH_FNOS_TOKEN_FILE:-/var/apps/gh-cli/target/etc/github-token}"

if [ -z "${GH_TOKEN:-}" ] && [ -z "${GITHUB_TOKEN:-}" ]; then
  for f in "$TOKEN_FILE" /var/apps/gh-cli/var/github-token; do
    [ -r "$f" ] || continue
    # 只取第一个非空、非注释行，避免把文件里的说明文字当成 token
    tok="$(sed -n '/^[[:space:]]*[^[:space:]#]/ { p; q; }' "$f" 2>/dev/null | tr -d '\r\n')"
    if [ -n "$tok" ]; then
      export GH_TOKEN="$tok"
      break
    fi
  done
fi

if [ ! -x "$REAL" ]; then
  echo "gh: 找不到可执行文件 $REAL（应用安装不完整？）" >&2
  exit 127
fi

exec "$REAL" "$@"
