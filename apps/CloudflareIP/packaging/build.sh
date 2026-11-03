#!/usr/bin/env bash
# ==============================================================================
# CloudflareIP · payload 生产线
#
# 由 FnFactory 的 _build-fpk.yml 或本仓库 build-local.sh 调用，只负责把产物
# 铺进 $PAYLOAD_DIR（= <workspace>/CloudflareIP/app）。包里最终长这样：
#
#   app/bin/cloudflareip               从仓库内 apps/CloudflareIP/src 编译出来的静态二进制
#   app/share/README.md                工具自带的说明（随源码一起入库）
#   app/share/PROVENANCE.json          版本 / 源码 sha256 / 二进制 sha256 / 工具链
#   app/apply-config.sh                模板里已有，不经本脚本
#
# 载体选择（fnos-fpk-porting 的「三选一」）：源码就在本仓库里，**自己编**
# 而不是取预编译产物 —— 工具是纯标准库 Go，CGO_ENABLED=0 静态链接，
# 交叉编译零依赖，且版本号能写进二进制（-X main.version），可事后核对。
#
# 纪律：
#   · 只读仓库内的 src/，不联网、不 clone、不改源码；
#   · 编完核对 ELF 架构，避免把 amd64 塞进 arm 包；
#   · 二进制在包里必须可执行（0755），飞牛安装时不一定替我们补位。
# ==============================================================================
set -euo pipefail

ARCH="${ARCH:?ARCH is required (arm64|amd64)}"
VERSION="${VERSION:?VERSION is required（包版本，例 1.0.0 或 1.0.0-2）}"
PAYLOAD_DIR="${PAYLOAD_DIR:?PAYLOAD_DIR is required}"
PLATFORM="${PLATFORM:-}"

APP_KEY="CloudflareIP"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/src"
BIN="$PAYLOAD_DIR/bin/cloudflareip"

log() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

case "$ARCH" in
  arm64|amd64) ;;
  *) echo "unsupported ARCH=$ARCH" >&2; exit 2 ;;
esac
: "${PLATFORM:=$([ "$ARCH" = arm64 ] && echo arm || echo x86)}"

# 包版本两段：上游/功能版本 + 打包修订号（只改打包时用 -2、-3）。
BASE_VERSION="$(printf '%s' "$VERSION" | sed -E 's/-[0-9]+$//')"

command -v go >/dev/null 2>&1 || { echo "需要 go 工具链（>= 1.27）；CI 里由 packaging/needs-go 触发 setup-go" >&2; exit 3; }
[ -d "$SRC" ] || { echo "缺少源码目录 $SRC" >&2; exit 4; }
[ -f "$SRC/go.mod" ] || { echo "$SRC 里没有 go.mod（源码没入库？）" >&2; exit 4; }

# 标准库漏洞只能靠「用修好的 Go 重编」解决，所以钉工具链而不是随 runner 漂移。
GO_TOOLCHAIN="${GO_TOOLCHAIN:-go1.27.3}"
export GOTOOLCHAIN="$GO_TOOLCHAIN"
log "toolchain: $(go version) (pinned GOTOOLCHAIN=$GO_TOOLCHAIN)"
log "target: linux/$ARCH · 包版本 $VERSION · 源码 $SRC"

# ── 1. 构建 ──────────────────────────────────────────────────────────────────
log "go build (CGO_ENABLED=0, -trimpath)"
mkdir -p "$PAYLOAD_DIR/bin" "$PAYLOAD_DIR/share"
(
  cd "$SRC"
  # 只读构建：-mod=mod 会写 go.sum；这里没有外部依赖，直接用默认行为并清 GOFLAGS。
  env -u GOFLAGS CGO_ENABLED=0 GOOS=linux GOARCH="$ARCH" GOTOOLCHAIN="$GO_TOOLCHAIN" \
    go build -trimpath -buildvcs=false \
      -ldflags "-s -w -X main.version=${BASE_VERSION}" \
      -o "$BIN" .
)
chmod 0755 "$BIN"
[ -s "$BIN" ] || { echo "构建产物为空：$BIN" >&2; exit 5; }

# ── 2. 核对 ELF 架构 ────────────────────────────────────────────────────────
# ELF e_machine（偏移 18 字节，小端）：0xB7=aarch64，0x3E=x86-64
MACHINE="$(od -An -tx1 -j18 -N2 "$BIN" | tr -d ' \n')"
case "$ARCH:$MACHINE" in
  arm64:b700)  ;;
  amd64:3e00)  ;;
  *) echo "ELF 架构与 ARCH=$ARCH 不符（e_machine=$MACHINE）" >&2; exit 6 ;;
esac
log "ELF 架构核对通过：$ARCH ($MACHINE)"

# ── 3. 附随文件与来源信息 ───────────────────────────────────────────────────
[ -f "$SRC/README.md" ] && install -m 0644 "$SRC/README.md" "$PAYLOAD_DIR/share/README.md"
if [ -f "$ROOT/../../../LICENSE" ]; then
  install -m 0644 "$ROOT/../../../LICENSE" "$PAYLOAD_DIR/share/LICENSE"
fi

BIN_SHA="$(sha256sum "$BIN" | awk '{print $1}')"
SRC_SHA="$(cd "$SRC" && find . -type f \( -name '*.go' -o -name '*.html' -o -name 'go.mod' \) -print0 \
            | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')"
GO_VER="$(go env GOVERSION 2>/dev/null || go version | awk '{print $3}')"

cat > "$PAYLOAD_DIR/share/PROVENANCE.json" <<EOF
{
  "app": "${APP_KEY}",
  "project": "https://github.com/bekafka/FnDepot/tree/main/apps/${APP_KEY}",
  "package_version": "${VERSION}",
  "functional_version": "${BASE_VERSION}",
  "source_author": "bekafka",
  "payload": {
    "kind": "built-from-vendored-source",
    "source_dir": "apps/${APP_KEY}/src",
    "source_sha256": "${SRC_SHA}",
    "binary": "bin/cloudflareip",
    "binary_sha256": "${BIN_SHA}",
    "arch": "${ARCH}",
    "platform": "${PLATFORM}",
    "elf_machine": "${MACHINE}",
    "go_version": "${GO_VER}",
    "build_flags": "CGO_ENABLED=0 GOOS=linux -trimpath -ldflags=-s -w",
    "note": "纯 Go 标准库实现，静态链接无 glibc 依赖；源码随包仓库入库，可复现构建"
  },
  "packaged_by": "bekafka/FnDepot",
  "packaged_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
EOF

log "payload 就绪"
find "$PAYLOAD_DIR" -type f -printf '  %-52p %10s\n' | sort || true
