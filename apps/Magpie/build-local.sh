#!/usr/bin/env bash
# ==============================================================================
# 本地出包（等价于 FnFactory 的 _build-fpk.yml + FnDepot 的 build-app.yml）
#
#   ARCH=arm64 VERSION=0.1.1279 CHANGELOG="首版" bash build-local.sh
#   ARCH=amd64 VERSION=0.1.1279 bash build-local.sh
#
# 流程：payload 生产线（packaging/build.sh）→ 组装工作区 → 注入 manifest 占位符
#       → fnpack build → dist/Magpie-<version>-<platform>.fpk
# ==============================================================================
set -euo pipefail

ARCH="${ARCH:-arm64}"
VERSION="${VERSION:?VERSION is required (upstream tag without the leading v)}"
CHANGELOG="${CHANGELOG:-跟随上游版本重新打包}"
APP_KEY="Magpie"

case "$ARCH" in
  arm64) PLATFORM="arm" ;;
  amd64) PLATFORM="x86" ;;
  *) echo "unsupported ARCH=$ARCH" >&2; exit 2 ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"
WORK="$REPO_ROOT/.build"
PAYLOAD_DIR="$WORK/payload"
WORKSPACE="$WORK/workspace"

FNPACK_BIN="${FNPACK_BIN:-}"
if [ -z "$FNPACK_BIN" ]; then
  for c in \
    "$REPO_ROOT/../../../FnFactory/tools/fnpack-linux-amd64" \
    "$HOME/dotfiles/ai/.agents/skills/Fnos/fnos-fpk-builder/bin/fnpack-linux-amd64" \
    "/usr/local/bin/fnpack"; do
    [ -x "$c" ] && { FNPACK_BIN="$c"; break; }
  done
fi
[ -n "$FNPACK_BIN" ] && [ -x "$FNPACK_BIN" ] || {
  echo "找不到 fnpack（用 FNPACK_BIN 指定）" >&2; exit 3; }

log() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

# ── 1. 组装工作区（先放模板，再让 build.sh 往 app/ 里产出 payload） ────────────
# 顺序有意：build.sh 会把面板密钥写进 bin/webkey，并替换 `../ui/config` 里的
# `__WEB_KEY__`（飞牛入口 URL 只认字面量，见 packaging/build.sh 注释）。
log "assembling build workspace"
rm -rf "$WORKSPACE" "$PAYLOAD_DIR"
mkdir -p "$WORKSPACE"
cp -a "$REPO_ROOT/package" "$WORKSPACE/$APP_KEY"
PAYLOAD_DIR="$WORKSPACE/$APP_KEY/app"
mkdir -p "$PAYLOAD_DIR"

log "producing payload (ARCH=$ARCH VERSION=$VERSION)"
ARCH="$ARCH" PLATFORM="$PLATFORM" VERSION="$VERSION" PAYLOAD_DIR="$PAYLOAD_DIR" \
  bash "$REPO_ROOT/packaging/build.sh"

chmod 0755 "$WORKSPACE/$APP_KEY/app/bin/magpie" "$WORKSPACE/$APP_KEY/app/bin/magpie-cli" \
            "$WORKSPACE/$APP_KEY/app/apply-config.sh" "$WORKSPACE/$APP_KEY"/cmd/* 2>/dev/null || true
cp "$FNPACK_BIN" "$WORKSPACE/fnpack"
chmod +x "$WORKSPACE/fnpack"

# ── 3. 注入 manifest 占位符（不用 sed：changelog 里可能有 / & 中文） ───────────
log "injecting manifest placeholders"
MANIFEST="$WORKSPACE/$APP_KEY/manifest"
export MANIFEST VERSION PLATFORM CHANGELOG
python3 - <<'PY'
import os, re
path = os.environ["MANIFEST"]
text = open(path, encoding="utf-8").read()
for key in ("VERSION", "PLATFORM", "CHANGELOG"):
    val = os.environ[key].replace("\n", " ")
    text = text.replace("${%s}" % key, val)
open(path, "w", encoding="utf-8").write(text)
PY
grep -E '^(appname|version|platform|changelog)' "$MANIFEST"

# ── 4. fnpack build ──────────────────────────────────────────────────────────
log "fnpack build"
mkdir -p "$REPO_ROOT/dist"
( cd "$WORKSPACE" && ./fnpack build "$APP_KEY" )
SRC_FPK="$(ls "$WORKSPACE"/*.fpk | head -n 1)"
OUT="$REPO_ROOT/dist/$APP_KEY-$VERSION-$PLATFORM.fpk"
mv "$SRC_FPK" "$OUT"

log "artifact"
ls -la "$OUT"
sha256sum "$OUT" | tee "$OUT.sha256"
