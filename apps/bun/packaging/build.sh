#!/usr/bin/env bash
# ==============================================================================
# bun · payload 生产线（载体：bun 官方「单文件可执行」release 资产）
#
# 由 FnFactory 的 _build-fpk.yml 或本仓库 build-local.sh 调用，只负责把产物
# 铺进 $PAYLOAD_DIR（= <workspace>/bun/app）。包里最终长这样：
#
#   app/bin/bun                         官方独立可执行文件（Zig 构建，约 99 MB）
#   app/bin/bunx                        bun x 的别名入口（软链 → bun）
#   app/bun-link.sh                     命令入口助手（模板里已有，不经本脚本）
#   app/share/LICENSE.md                MIT 许可原文（再分发义务）
#   app/share/PROVENANCE.json           版本 / 资产 sha256 / 二进制 sha256 / 下载地址
#
# 与 pnpm / uv 包的三处关键差异：
#   1. **上游 tag 形如 `bun-v1.4.4`**（前缀是 bun-v），所以 TAG="bun-v${VERSION}"；
#   2. **资产是 zip 不是 tar.gz**，命名 `bun-linux-x64.zip` / `bun-linux-aarch64.zip`
#      （还有 baseline / musl / profile 变体，这里固定取标准 gnu 版）；
#   3. **校验用一份汇总清单 SHASUMS256.txt**（一行一个「摘要 + 文件名」），
#      一次下载就能覆盖两个架构，比逐资产 .sha256 更省请求。
# ==============================================================================
set -euo pipefail

ARCH="${ARCH:?ARCH is required (arm64|amd64)}"
VERSION="${VERSION:?VERSION is required (上游版本号，不含 bun-v 前缀)}"
PAYLOAD_DIR="${PAYLOAD_DIR:?PAYLOAD_DIR is required}"

UPSTREAM_REPO="oven-sh/bun"
TAG="bun-v${VERSION}"                 # bun 的 tag 形如 bun-v1.4.4
CACHE_DIR="${CACHE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.build/cache}"
PROXY="${BUN_DL_PROXY:-}"
DL_BASE="${BUN_DL_BASE:-https://github.com}"

log() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

case "$ARCH" in
  arm64) ASSET="bun-linux-aarch64.zip"; ELF_WANT="b700" ;;
  amd64) ASSET="bun-linux-x64.zip"     ; ELF_WANT="3e00" ;;
  *) echo "unsupported ARCH=$ARCH" >&2; exit 2 ;;
esac

CURL=(curl -fsSL --retry 3 --retry-delay 2 --retry-connrefused -m 1800)
[ -n "$PROXY" ] && CURL+=(--proxy "$PROXY")

mkdir -p "$CACHE_DIR/$VERSION"

fetch() { # $1=url $2=dest
  local url="$1" dest="$2"
  if [ -s "$dest" ]; then log "缓存命中：$(basename "$dest")"; return 0; fi
  rm -f "$dest.part"
  log "下载 $url"
  if "${CURL[@]}" -o "$dest.part" "$url"; then mv -f "$dest.part" "$dest"; return 0; fi
  rm -f "$dest.part"; return 1
}

# ── 1. 取汇总校验清单，挑出本架构那一行 ─────────────────────────────────────
SUMS="$CACHE_DIR/$VERSION/SHASUMS256.txt"
fetch "$DL_BASE/$UPSTREAM_REPO/releases/download/$TAG/SHASUMS256.txt" "$SUMS" || {
  echo "取不到 SHASUMS256.txt，无法校验，停止打包" >&2; exit 3; }

# SHASUMS256.txt 每行形如「<sha256>  <文件名>」（有些行文件名前带 * 号）
EXPECTED="$(awk -v want="$ASSET" '
  { name = $NF; sub(/^\*/, "", name); if (name == want) { print $1; exit } }
' "$SUMS")"
[ -n "$EXPECTED" ] || { echo "SHASUMS256.txt 里没有 $ASSET 的摘要" >&2; exit 3; }
log "校验源：SHASUMS256.txt → $ASSET"

# ── 2. 下载资产并校验 ───────────────────────────────────────────────────────
fetch "$DL_BASE/$UPSTREAM_REPO/releases/download/$TAG/$ASSET" "$CACHE_DIR/$VERSION/$ASSET"
ACTUAL="$(sha256sum "$CACHE_DIR/$VERSION/$ASSET" | awk '{print $1}')"
if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "sha256 不符：期望 $EXPECTED 实际 $ACTUAL（上游可能重传了资产，删缓存重试）" >&2
  exit 4
fi
log "sha256 校验通过：$ACTUAL"

# ── 3. 解 zip、找可执行文件、核对架构 ───────────────────────────────────────
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
python3 - "$CACHE_DIR/$VERSION/$ASSET" "$WORK" <<'PY'
import sys, zipfile
zf, dest = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(zf) as z:
    z.extractall(dest)
PY

BIN_BUN="$(find "$WORK" -type f -name bun -perm -u+x -print -quit 2>/dev/null || true)"
[ -n "$BIN_BUN" ] || BIN_BUN="$(find "$WORK" -type f -name bun -print -quit 2>/dev/null || true)"
[ -n "$BIN_BUN" ] || {
  echo "zip 里没有 bun 可执行文件（实际内容：$(find "$WORK" -type f | head -5 | tr '\n' ' ')）" >&2
  exit 5; }

MACHINE="$(od -An -tx1 -j18 -N2 "$BIN_BUN" | tr -d ' \n')"
if [ "$MACHINE" != "$ELF_WANT" ]; then
  echo "ELF 架构与 ARCH=$ARCH 不符（e_machine=$MACHINE，期望 $ELF_WANT）" >&2
  exit 6
fi
log "ELF 架构核对通过：$ARCH ($MACHINE)"

# ── 4. 铺进 payload ─────────────────────────────────────────────────────────
mkdir -p "$PAYLOAD_DIR/bin" "$PAYLOAD_DIR/share"
install -m 0755 "$BIN_BUN" "$PAYLOAD_DIR/bin/bun"
# bunx 是同一个二进制按 argv[0] 分派的别名入口（等价于 `bun x`），上游 npm 包也是软链形态；
# 这里建同名软链，让「命令入口声明两条」在包内真的成立。
ln -sfn bun "$PAYLOAD_DIR/bin/bunx"
log "已建立 bin/bunx → bun 软链（bun 按调用名分派，行为等价于 bun x）"

# 许可证：MIT
for f in LICENSE.md LICENSE; do
  if fetch "$DL_BASE/$UPSTREAM_REPO/raw/$TAG/$f" "$CACHE_DIR/$VERSION/$f"; then
    install -m 0644 "$CACHE_DIR/$VERSION/$f" "$PAYLOAD_DIR/share/LICENSE.md"
    break
  fi
done
[ -f "$PAYLOAD_DIR/share/LICENSE.md" ] || echo "::warning::取不到上游许可证原文（不影响出包，但再分发许可文本不完整）" >&2

BIN_SHA="$(sha256sum "$PAYLOAD_DIR/bin/bun" | awk '{print $1}')"

cat > "$PAYLOAD_DIR/share/PROVENANCE.json" <<EOF
{
  "app": "bun",
  "upstream_repo": "https://github.com/${UPSTREAM_REPO}",
  "upstream_tag": "${TAG}",
  "upstream_version": "${VERSION}",
  "license": "MIT",
  "source_author": "oven-sh",
  "payload": {
    "kind": "prebuilt-standalone-binary",
    "asset": "${ASSET}",
    "asset_url": "${DL_BASE}/${UPSTREAM_REPO}/releases/download/${TAG}/${ASSET}",
    "asset_sha256": "${ACTUAL}",
    "binary": "bin/bun",
    "binary_sha256": "${BIN_SHA}",
    "second_binary": "bin/bunx",
    "second_binary_kind": "symlink-to-bun",
    "arch": "${ARCH}",
    "asset_platform": "${ASSET%.zip}",
    "elf_machine": "${MACHINE}",
    "note": "官方 Zig 静态构建：bun 自带 JS 运行时与包管理器，运行时不依赖系统 Node.js；Linux 取标准 gnu 版（baseline/musl/profile 变体不取）"
  },
  "packaged_by": "${UPSTREAM_REPO}",
  "packaged_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
EOF

log "payload 就绪"
find "$PAYLOAD_DIR" -type f -printf '  %-52p %10s\n' | sort || true
ls -l "$PAYLOAD_DIR/bin" || true
