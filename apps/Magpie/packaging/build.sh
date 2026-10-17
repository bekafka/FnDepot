#!/usr/bin/env bash
# ==============================================================================
# Magpie · payload 生产线
#
# 从上游源码 tag 构建 Linux 二进制（纯 Go，CGO_ENABLED=0，可交叉编译）：
#   · 只用 nogui 构建：不带 GTK/Wails 桌面壳，保留 Web 面板 + CLI + 网关
#   · 版本号写进二进制（-X main.version=vX.Y.Z），`magpie version` 可核对
#   · 产物落到 $PAYLOAD_DIR/bin/magpie，并写 PROVENANCE.json（commit/sha256/go 版本）
#
# 环境变量：
#   VERSION       必填，上游 tag 去掉 v（如 0.1.1279）
#   ARCH          必填，amd64 | arm64
#   PLATFORM      可选，x86 | arm（只用于 PROVENANCE 记录）
#   PAYLOAD_DIR   可选，默认 ./.build/payload/app
#   MAGPIE_UPSTREAM 可选，默认 https://github.com/yetone/magpie.git
# ==============================================================================
set -euo pipefail

VERSION="${VERSION:?VERSION is required（包版本，例 0.1.1279 或 0.1.1279-2）}"
ARCH="${ARCH:?ARCH is required (amd64|arm64)}"
case "$ARCH" in
  amd64|arm64) ;;
  *) echo "unsupported ARCH=$ARCH" >&2; exit 2 ;;
esac
PLATFORM="${PLATFORM:-$([ "$ARCH" = amd64 ] && echo x86 || echo arm)}"

# 包版本 = 上游版本 [+ 打包修订号]：
#   0.1.1279    → 上游 tag v0.1.1279
#   0.1.1279-2  → 同一上游 tag，第 2 次打包（只改了生命周期/向导/文案，上游没升版）
# 二进制里写的始终是上游版本，PROVENANCE 里两个都记。
BASE_VERSION="$(printf '%s' "$VERSION" | sed -E 's/-[0-9]+$//')"
case "$BASE_VERSION" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "VERSION 的上游部分不合法：$VERSION（期望 x.y.z 或 x.y.z-r）" >&2; exit 2 ;;
esac
TAG="v$BASE_VERSION"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAYLOAD_DIR="${PAYLOAD_DIR:-$ROOT/.build/payload/app}"
UPSTREAM="${MAGPIE_UPSTREAM:-https://github.com/yetone/magpie.git}"
SRC="$ROOT/.build/upstream/magpie-$TAG"
BIN="$PAYLOAD_DIR/bin/magpie"

log() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

command -v git >/dev/null 2>&1 || { echo "需要 git" >&2; exit 3; }
command -v go >/dev/null 2>&1 || { echo "需要 go（>= 1.26.3；GOTOOLCHAIN=auto 可自动取）" >&2; exit 3; }
GO_VERSION_RAW="$(go version)"
log "toolchain: $GO_VERSION_RAW (host $(uname -m))"
log "target: linux/$ARCH · 包版本 $VERSION · 上游 tag $TAG"

# ── 1. 源码：浅克隆指定 tag（缓存复用；缓存损坏时重建） ──────────────────────
if [ -d "$SRC/.git" ]; then
  if ! git -C "$SRC" describe --tags --exact-match 2>/dev/null | grep -qx "$TAG"; then
    log "缓存 tag 不符，重建 $SRC"
    rm -rf "$SRC"
  fi
fi
if [ ! -d "$SRC/.git" ]; then
  log "clone $UPSTREAM @ $TAG"
  mkdir -p "$(dirname "$SRC")"
  git clone --depth 1 --branch "$TAG" "$UPSTREAM" "$SRC"
fi
COMMIT="$(git -C "$SRC" rev-parse HEAD)"
ACTUAL_TAG="$(git -C "$SRC" describe --tags --exact-match 2>/dev/null || true)"
[ "$ACTUAL_TAG" = "$TAG" ] || { echo "源码 tag 不符：期望 $TAG，实际 ${ACTUAL_TAG:-?}" >&2; exit 4; }
log "commit $COMMIT"

# ── 2. 构建 ──────────────────────────────────────────────────────────────────
mkdir -p "$PAYLOAD_DIR/bin"
log "go build (-tags nogui, CGO_ENABLED=0)"
(
  cd "$SRC"
  CGO_ENABLED=0 GOOS=linux GOARCH="$ARCH" GOTOOLCHAIN=auto \
    go build -tags nogui -trimpath \
    -ldflags "-s -w -X main.version=$TAG" \
    -o "$BIN" .
)
[ -x "$BIN" ] || { echo "构建产物不存在：$BIN" >&2; exit 5; }

# ── 3. 核对产物：架构、版本、模块信息 ─────────────────────────────────────────
MACHINE="$(go version -m "$BIN" 2>/dev/null | sed -n 's/^\tbuild\tGOARCH=//p' | head -n 1)"
[ -n "$MACHINE" ] || MACHINE="$(readelf -h "$BIN" 2>/dev/null | sed -n 's/^ *Machine: *//p' | head -n 1)"
case "$ARCH:$MACHINE" in
  amd64:amd64|amd64:x86-64|amd64:x86_64|x86-64:x86-64|arm64:arm64|arm64:AArch64|arm64:aarch64) ;;
  *) echo "产物架构不符：期望 $ARCH，实际 ${MACHINE:-未知}" >&2; exit 6 ;;
esac
if [ "$(uname -m)" = "x86_64" ] && [ "$ARCH" = "amd64" ]; then
  GOT="$( "$BIN" version 2>&1 | head -n 1 )"
  echo "  built binary reports: $GOT"
  case "$GOT" in *"$TAG"*) ;; *) echo "二进制版本自检失败：$GOT" >&2; exit 7 ;; esac
fi

# ── 3.5 面板登录密钥：构建时写死 ───────────────────────────────────────────────
# 飞牛的桌面入口 URL 只认字面量：`${wizard_*}` / `${wizard_path}` 放在查询串里不会被替换
# （实测请求直接变成 `/`，查询串整个丢掉）。所以 key 必须在打包时就存在，
# 同时写进 payload 的 bin/webkey 和入口 URL；安装脚本只负责把它落到数据目录。
KEY_FILE="$ROOT/packaging/webkey"
[ -r "$KEY_FILE" ] || { echo "缺少 $KEY_FILE（面板登录密钥）" >&2; exit 8; }
WEB_KEY="$(tr -d '[:space:]' < "$KEY_FILE")"
case "$WEB_KEY" in
  *[!A-Za-z0-9._~-]*|'') echo "packaging/webkey 不合法（只允许 16-64 位字母数字 . _ ~ -）：$WEB_KEY" >&2; exit 8 ;;
esac
[ ${#WEB_KEY} -ge 16 ] || { echo "packaging/webkey 太短（至少 16 位）" >&2; exit 8; }
printf '%s\n' "$WEB_KEY" > "$PAYLOAD_DIR/bin/webkey"
chmod 0600 "$PAYLOAD_DIR/bin/webkey"

UI_CONFIG="$PAYLOAD_DIR/ui/config"
if [ -f "$UI_CONFIG" ]; then
  sed "s/__WEB_KEY__/$WEB_KEY/g" "$UI_CONFIG" > "$UI_CONFIG.tmp" && mv "$UI_CONFIG.tmp" "$UI_CONFIG"
  grep -q "\?k=$WEB_KEY" "$UI_CONFIG" || { echo "入口 URL 注入失败：$UI_CONFIG" >&2; exit 8; }
  echo "  入口 URL 已写入面板密钥（$UI_CONFIG）"
else
  echo "警告：找不到 $UI_CONFIG（没有先组装包模板？），入口里的 __WEB_KEY__ 未被替换" >&2
fi

# ── 4. PROVENANCE ────────────────────────────────────────────────────────────
SHA="$(sha256sum "$BIN" | awk '{print $1}')"
SIZE="$(stat -c%s "$BIN")"
cat > "$PAYLOAD_DIR/PROVENANCE.json" <<EOF
{
  "upstream": "https://github.com/yetone/magpie",
  "tag": "$TAG",
  "package_version": "$VERSION",
  "commit": "$COMMIT",
  "build": {
    "goos": "linux",
    "goarch": "$ARCH",
    "platform": "$PLATFORM",
    "tags": "nogui",
    "ldflags": "-s -w -X main.version=$TAG",
    "cgo": false,
    "go_version": "$(printf '%s' "$GO_VERSION_RAW" | awk '{print $3}')",
    "built_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
    "builder": "$(hostname 2>/dev/null || echo unknown)"
  },
  "binary": {
    "path": "bin/magpie",
    "sha256": "$SHA",
    "size": $SIZE
  }
}
EOF

# 许可证随包（MIT）
cp "$SRC/LICENSE" "$PAYLOAD_DIR/LICENSE" 2>/dev/null || true

log "payload ready"
printf '  %s  %s bytes  sha256=%s\n' "$BIN" "$SIZE" "$SHA"
