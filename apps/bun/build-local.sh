#!/usr/bin/env bash
# ==============================================================================
# 本地出包（等价于 FnFactory 的 _build-fpk.yml + FnDepot 的 build-app.yml）
#
#   ARCH=arm64 VERSION=1.4.4 CHANGELOG="首版" bash build-local.sh
#   ARCH=amd64 VERSION=1.4.4 bash build-local.sh
#
# 注意：bun 的上游 tag 形如 bun-v1.4.4，这里 VERSION 只写版本号 1.4.4（脚本自己拼 bun-v 前缀）。
# ==============================================================================
set -euo pipefail

ARCH="${ARCH:-arm64}"
VERSION="${VERSION:?VERSION is required (只写版本号，如 1.4.4；不含 bun-v 前缀)}"
CHANGELOG="${CHANGELOG:-跟随上游版本重新打包}"
APP_KEY="bun"

case "$ARCH" in
  arm64) PLATFORM="arm" ;;
  amd64) PLATFORM="x86" ;;
  *) echo "unsupported ARCH=$ARCH" >&2; exit 2 ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"
WORK="$REPO_ROOT/.build"
PAYLOAD_DIR="$WORK/workspace/$APP_KEY/app"

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

# ── 1. 组装工作区 ───────────────────────────────────────────────────────────
log "assembling build workspace"
rm -rf "$WORK/workspace"
mkdir -p "$WORK/workspace"
cp -a "$REPO_ROOT/package" "$WORK/workspace/$APP_KEY"
mkdir -p "$PAYLOAD_DIR"

log "producing payload (ARCH=$ARCH VERSION=$VERSION)"
ARCH="$ARCH" PLATFORM="$PLATFORM" VERSION="$VERSION" PAYLOAD_DIR="$PAYLOAD_DIR" \
  bash "$REPO_ROOT/packaging/build.sh"

chmod 0755 "$WORK/workspace/$APP_KEY/app/bin/bun" \
            "$WORK/workspace/$APP_KEY/app/bin/bunx" \
            "$WORK/workspace/$APP_KEY/app/bun-link.sh" \
            "$WORK/workspace/$APP_KEY"/cmd/* 2>/dev/null || true
cp "$FNPACK_BIN" "$WORK/workspace/fnpack"
chmod +x "$WORK/workspace/fnpack"

# ── 2. 注入 manifest 占位符 ─────────────────────────────────────────────────
log "injecting manifest placeholders"
export MANIFEST="$WORK/workspace/$APP_KEY/manifest"
export VERSION PLATFORM CHANGELOG
python3 - <<'PY'
import os
path = os.environ["MANIFEST"]
text = open(path, encoding="utf-8").read()
for key in ("VERSION", "PLATFORM", "CHANGELOG"):
    text = text.replace("${%s}" % key, os.environ[key].replace("\n", " "))
open(path, "w", encoding="utf-8").write(text)
PY
grep -E '^(appname|version|platform|changelog)' "$MANIFEST"

# ── 3. 打包前跑一遍规范门禁（校验源模板，应用自带作者口径）──────────────────
LINT="$REPO_ROOT/../../../FnFactory/tools/lint-package.sh"
if [ -x "$LINT" ]; then
  log "lint-package（源模板）"
  if [ -f "$REPO_ROOT/authorship.env" ]; then
    # shellcheck disable=SC1091
    . "$REPO_ROOT/authorship.env"
    export FACTORY_OWNERS
    log "作者口径：FACTORY_OWNERS=${FACTORY_OWNERS:-（未声明）}"
  fi
  bash "$LINT" "$REPO_ROOT/package" || echo "（lint 未全过：见上方逐条判读）"
fi

# ── 4. fnpack build ─────────────────────────────────────────────────────────
log "fnpack build"
mkdir -p "$REPO_ROOT/dist"
( cd "$WORK/workspace" && ./fnpack build "$APP_KEY" )
SRC_FPK="$(ls "$WORK/workspace"/*.fpk | head -n 1)"
OUT="$REPO_ROOT/dist/$APP_KEY-$VERSION-$PLATFORM.fpk"
mv "$SRC_FPK" "$OUT"

log "artifact"
ls -la "$OUT"
sha256sum "$OUT" | tee "$OUT.sha256"
