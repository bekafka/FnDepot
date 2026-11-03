#!/usr/bin/env bash
# ==============================================================================
# 本地出包（等价于 FnFactory 的 _build-fpk.yml + FnDepot 的 build-app.yml）
#
#   ARCH=arm64 VERSION=0.20.1 CHANGELOG="首版" bash build-local.sh
#   ARCH=amd64 VERSION=0.20.1 bash build-local.sh
#
# 顺序严格复刻 CI（顺序错了会出现「包能打、但注入静默落空」）：
#   1) 规范门禁（跑在模板上，注入前）→ 2) 复制模板到工作区 →
#   3) build.sh 产出 payload 到 <app>/app/ → 4) 注入 manifest 占位符并自校验 →
#   5) fnpack build
# ==============================================================================
set -euo pipefail

ARCH="${ARCH:-arm64}"
VERSION="${VERSION:?VERSION is required（例 0.20.1 或 0.20.1-2）}"
CHANGELOG="${CHANGELOG:-跟随上游重新打包}"
APP_KEY="PhotoCraft"

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
[ -n "$FNPACK_BIN" ] && [ -x "$FNPACK_BIN" ] || { echo "找不到 fnpack（用 FNPACK_BIN 指定）" >&2; exit 3; }

log() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

LINT="$REPO_ROOT/../../../FnFactory/tools/lint-package.sh"
if [ -x "$LINT" ]; then
  log "lint-package（模板，注入前）"
  bash "$LINT" "$REPO_ROOT/package" || { echo "lint 未通过，先别发版" >&2; exit 3; }
fi

log "assembling build workspace"
rm -rf "$WORK/workspace"
mkdir -p "$WORK/workspace"
cp -a "$REPO_ROOT/package" "$WORK/workspace/$APP_KEY"
mkdir -p "$PAYLOAD_DIR"

log "producing payload (ARCH=$ARCH VERSION=$VERSION)"
ARCH="$ARCH" PLATFORM="$PLATFORM" VERSION="$VERSION" PAYLOAD_DIR="$PAYLOAD_DIR" \
  bash "$REPO_ROOT/packaging/build.sh"

chmod 0755 "$WORK/workspace/$APP_KEY/app/bin/photocraft-web" \
            "$WORK/workspace/$APP_KEY/app/apply-config.sh" \
            "$WORK/workspace/$APP_KEY"/cmd/* 2>/dev/null || true
cp "$FNPACK_BIN" "$WORK/workspace/fnpack"
chmod +x "$WORK/workspace/fnpack"

log "injecting manifest placeholders"
export MANIFEST="$WORK/workspace/$APP_KEY/manifest"
export VERSION PLATFORM CHANGELOG
python3 - <<'PY'
import os
path = os.environ["MANIFEST"]
text = open(path, encoding="utf-8").read()
for key in ("VERSION", "PLATFORM", "CHANGELOG"):
    val = os.environ[key].replace("\n", " ")
    if "${%s}" % key not in text:
        raise SystemExit(f"manifest 里没有占位符 ${{{key}}}，注入会静默落空")
    text = text.replace("${%s}" % key, val)
open(path, "w", encoding="utf-8").write(text)
PY
grep -q "^version.*= $VERSION$" "$MANIFEST" || { echo "version 注入失败" >&2; exit 4; }
grep -q "^platform.*= $PLATFORM$" "$MANIFEST" || { echo "platform 注入失败" >&2; exit 4; }
grep -E '^(appname|version|platform|changelog)' "$MANIFEST"

log "fnpack build"
mkdir -p "$REPO_ROOT/dist"
( cd "$WORK/workspace" && ./fnpack build "$APP_KEY" ) | tee /tmp/fnpack-photocraft.log
grep -q 'Packing successfully' /tmp/fnpack-photocraft.log || { echo "fnpack 未报告成功" >&2; exit 5; }
SRC_FPK="$(find "$WORK/workspace" -maxdepth 1 -type f -name '*.fpk' | head -n 1)"
[ -n "$SRC_FPK" ] || { echo "没有产出 .fpk" >&2; exit 6; }
OUT="$REPO_ROOT/dist/$APP_KEY-$VERSION-$PLATFORM.fpk"
mv "$SRC_FPK" "$OUT"

log "artifact"
ls -la "$OUT"
sha256sum "$OUT" | tee "$OUT.sha256"
