#!/usr/bin/env bash
# ==============================================================================
# 本地出包（等价于 fpk-factory 的 _build-fpk.yml + 打包厂工具）
#
#   ARCH=arm64 VERSION=2.0.0-beta.49 CHANGELOG="..." bash build-local.sh
#
# 流程：payload 生产线（packaging/build.sh）→ 组装工作区 → 注入 manifest 占位符
#       → fnpack build → dist/Motrix-<version>-<arch>.fpk
# ==============================================================================
set -euo pipefail

ARCH="${ARCH:-arm64}"
VERSION="${VERSION:?VERSION is required}"
CHANGELOG="${CHANGELOG:-重新打包：跟随上游 Motrix Server 发布}"
APP_KEY="Motrix"

case "$ARCH" in
  arm64) PLATFORM="arm" ;;
  amd64) PLATFORM="x86" ;;
  *) echo "unsupported ARCH=$ARCH" >&2; exit 2 ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"
WORK="$REPO_ROOT/.build"
PAYLOAD_CACHE="$WORK/payload/app"
FNPACK_BIN="${FNPACK_BIN:-$REPO_ROOT/../fpk-factory/tools/fnpack-linux-amd64}"
WORKSPACE="$REPO_ROOT/build_workspace"

log() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

# ── 1. payload ────────────────────────────────────────────────────────────────
log "producing payload (ARCH=$ARCH VERSION=$VERSION)"
ARCH="$ARCH" PLATFORM="$PLATFORM" VERSION="$VERSION" PAYLOAD_DIR="$PAYLOAD_CACHE" \
  bash "$REPO_ROOT/packaging/build.sh"

# ── 2. 组装工作区（模板 + payload） ───────────────────────────────────────────
log "assembling build workspace"
rm -rf "$WORKSPACE"
mkdir -p "$WORKSPACE"
cp -a "$REPO_ROOT/package" "$WORKSPACE/$APP_KEY"
rm -rf "$WORKSPACE/$APP_KEY/app/server"
cp -a "$PAYLOAD_CACHE/server" "$WORKSPACE/$APP_KEY/app/server"
cp -a "$PAYLOAD_CACHE/PROVENANCE.json" "$WORKSPACE/$APP_KEY/app/PROVENANCE.json"
[ -f "$PAYLOAD_CACHE/AUTH_MODE" ] && cp -a "$PAYLOAD_CACHE/AUTH_MODE" "$WORKSPACE/$APP_KEY/app/AUTH_MODE" || true
[ -x "$FNPACK_BIN" ] || { echo "fnpack not found: $FNPACK_BIN" >&2; exit 3; }
cp "$FNPACK_BIN" "$WORKSPACE/fnpack"; chmod +x "$WORKSPACE/fnpack"

# ── 3. 注入 manifest 占位符 ───────────────────────────────────────────────────
log "injecting manifest placeholders"
MANIFEST="$WORKSPACE/$APP_KEY/manifest"
VERSION="$VERSION" PLATFORM="$PLATFORM" CHANGELOG="$CHANGELOG" MANIFEST="$MANIFEST" \
  node -e '
    const fs = require("fs");
    const file = process.env.MANIFEST;
    let text = fs.readFileSync(file, "utf8");
    text = text.replaceAll("${VERSION}", process.env.VERSION);
    text = text.replaceAll("${PLATFORM}", process.env.PLATFORM);
    text = text.replaceAll("${CHANGELOG}", process.env.CHANGELOG.replace(/\n/g, " "));
    fs.writeFileSync(file, text);
  '
grep -E '^(appname|version|platform|install_dep_apps)' "$MANIFEST"

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
