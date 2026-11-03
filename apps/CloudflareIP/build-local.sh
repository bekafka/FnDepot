#!/usr/bin/env bash
# ==============================================================================
# 本地出包（等价于 FnFactory 的 _build-fpk.yml + FnDepot 的 build-app.yml）
#
#   ARCH=arm64 VERSION=1.0.0 CHANGELOG="首版" bash build-local.sh
#   ARCH=amd64 VERSION=1.0.0 bash build-local.sh
#
# 流程严格复刻 CI 的顺序（顺序错了会出现「包能打、但注入静默落空」）：
#   1) 复制模板到工作区  → 2) 跑 packaging/build.sh 产出 payload 到 <app>/app/
#   → 3) 注入 manifest 占位符并自校验 → 4) 规范门禁 → 5) fnpack build
# ==============================================================================
set -euo pipefail

ARCH="${ARCH:-arm64}"
VERSION="${VERSION:?VERSION is required（例 1.0.0 或 1.0.0-2）}"
CHANGELOG="${CHANGELOG:-跟随源码重新打包}"
APP_KEY="CloudflareIP"

case "$ARCH" in
  arm64) PLATFORM="arm" ;;
  amd64) PLATFORM="x86" ;;
  *) echo "unsupported ARCH=$ARCH" >&2; exit 2 ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"
WORK="$REPO_ROOT/.build"
PAYLOAD_DIR="$WORK/workspace/$APP_KEY/app"

# fnpack：优先用打包厂里那份（amd64 1.2.3 是两条流水线统一的版本）
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

# ── 0. 规范门禁（和 CI 同一条）。必须跑在【模板】上，不能跑在注入后的工作区：
#       injected 副本里 version/platform 已是具体值、目录名也叫 workspace，
#       manifest 契约检查会按设计报错，那 4 条 FAIL 是噪声不是问题。
LINT="$REPO_ROOT/../../../FnFactory/tools/lint-package.sh"
if [ -x "$LINT" ]; then
  log "lint-package（模板，注入前）"
  bash "$LINT" "$REPO_ROOT/package" || { echo "lint 未通过，先别发版" >&2; exit 3; }
fi

# ── 1. 组装工作区（先放模板，再让 build.sh 往 app/ 里产出 payload）────────────
log "assembling build workspace"
rm -rf "$WORK/workspace"
mkdir -p "$WORK/workspace"
cp -a "$REPO_ROOT/package" "$WORK/workspace/$APP_KEY"
mkdir -p "$PAYLOAD_DIR"

log "producing payload (ARCH=$ARCH VERSION=$VERSION)"
ARCH="$ARCH" PLATFORM="$PLATFORM" VERSION="$VERSION" PAYLOAD_DIR="$PAYLOAD_DIR" \
  bash "$REPO_ROOT/packaging/build.sh"

chmod 0755 "$WORK/workspace/$APP_KEY/app/bin/cloudflareip" \
            "$WORK/workspace/$APP_KEY/app/apply-config.sh" \
            "$WORK/workspace/$APP_KEY"/cmd/* 2>/dev/null || true
cp "$FNPACK_BIN" "$WORK/workspace/fnpack"
chmod +x "$WORK/workspace/fnpack"

# ── 2. 注入 manifest 占位符（不用 sed：changelog 里可能有 / & 中文）────────────
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
# 注入后自校验：写进去的值必须真的在文件里
grep -q "^version.*= $VERSION$" "$MANIFEST" || { echo "version 注入失败" >&2; exit 4; }
grep -q "^platform.*= $PLATFORM$" "$MANIFEST" || { echo "platform 注入失败" >&2; exit 4; }
grep -E '^(appname|version|platform|changelog)' "$MANIFEST"


# ── 4. fnpack build ─────────────────────────────────────────────────────────
log "fnpack build"
mkdir -p "$REPO_ROOT/dist"
( cd "$WORK/workspace" && ./fnpack build "$APP_KEY" ) | tee /tmp/fnpack-cloudflareip.log
grep -q 'Packing successfully' /tmp/fnpack-cloudflareip.log || { echo "fnpack 未报告成功" >&2; exit 5; }
SRC_FPK="$(find "$WORK/workspace" -maxdepth 1 -type f -name '*.fpk' | head -n 1)"
[ -n "$SRC_FPK" ] || { echo "没有产出 .fpk" >&2; exit 6; }
OUT="$REPO_ROOT/dist/$APP_KEY-$VERSION-$PLATFORM.fpk"
mv "$SRC_FPK" "$OUT"

log "artifact"
ls -la "$OUT"
sha256sum "$OUT" | tee "$OUT.sha256"
