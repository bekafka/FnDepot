#!/usr/bin/env bash
# ==============================================================================
# pnpm · payload 生产线（载体：pnpm 官方「单文件可执行」release 资产）
#
# 由 FnFactory 的 _build-fpk.yml 或本仓库 build-local.sh 调用，只负责把产物
# 铺进 $PAYLOAD_DIR（= <workspace>/pnpm/app）。包里最终长这样：
#
#   app/bin/pnpm                        官方独立可执行文件（Node 引擎已内嵌其中）
#   app/pnpm-link.sh                    命令入口助手（模板里已有，不经本脚本）
#   app/share/LICENSE                   MIT 许可证原文（再分发义务）
#   app/share/PROVENANCE.json           版本 / 资产 sha256 / 二进制 sha256 / 下载地址
#
# 纪律（FnFactory specs + fnos-fpk-builder）：
#   · 取上游官方产物，不自己编译（自编 pnpm 需要整套 Node 工具链，且行为易与官方漂移）；
#   · **pnpm 的 release 不发 SHA256SUMS 文件**，校验改用 GitHub release 元数据里
#     每个资产自带的 sha256 摘要（`digest` 字段）；取不到摘要就退出，绝不"记下实际值"；
#   · 解包后核对 ELF 架构，避免把 x64 塞进 arm 包；
#   · 官方资产名是 pnpm-linux-<x64|arm64>.tar.gz，和 fnOS 的 amd64/arm64 不是一套词，
#     映射写死在下面对照表里，不靠猜。
# ==============================================================================
set -euo pipefail

ARCH="${ARCH:?ARCH is required (arm64|amd64)}"
VERSION="${VERSION:?VERSION is required (upstream tag without the leading v)}"
PAYLOAD_DIR="${PAYLOAD_DIR:?PAYLOAD_DIR is required}"

UPSTREAM_REPO="pnpm/pnpm"
TAG="v${VERSION}"
CACHE_DIR="${CACHE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.build/cache}"
# 国内环境/CI 可用 PNPM_DL_PROXY 指定代理；留空表示直连
PROXY="${PNPM_DL_PROXY:-}"
API_BASE="${PNPM_API_BASE:-https://api.github.com}"
DL_BASE="${PNPM_DL_BASE:-https://github.com}"

log() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

case "$ARCH" in
  arm64) ASSET="pnpm-linux-arm64.tar.gz" ; ELF_WANT="b700" ;;
  amd64) ASSET="pnpm-linux-x64.tar.gz"   ; ELF_WANT="3e00" ;;
  *) echo "unsupported ARCH=$ARCH" >&2; exit 2 ;;
esac

CURL=(curl -fsSL --retry 3 --retry-delay 2 --retry-connrefused -m 1200)
[ -n "$PROXY" ] && CURL+=(--proxy "$PROXY")

mkdir -p "$CACHE_DIR/$TAG"
META="$CACHE_DIR/$TAG/release.json"

fetch() { # $1=url $2=dest
  local url="$1" dest="$2"
  if [ -s "$dest" ]; then
    log "缓存命中：$(basename "$dest")"
    return 0
  fi
  rm -f "$dest.part"
  log "下载 $url"
  "${CURL[@]}" -o "$dest.part" "$url"
  mv -f "$dest.part" "$dest"
}

# ── 1. 取 release 元数据，拿到上游自己登记的 sha256 摘要 ────────────────────
fetch "$API_BASE/repos/$UPSTREAM_REPO/releases/tags/$TAG" "$META"

EXPECTED="$(ASSET="$ASSET" python3 - "$META" <<'PY'
import json, os, sys
asset_name = os.environ["ASSET"]
data = json.load(open(sys.argv[1]))
for a in data.get("assets", []):
    if a.get("name") == asset_name:
        digest = a.get("digest") or ""
        if digest.startswith("sha256:"):
            print(digest.split(":", 1)[1])
        break
PY
)"
[ -n "$EXPECTED" ] || {
  echo "release 元数据里没有 $ASSET 的 sha256 摘要（上游可能改了校验方式，停止打包）" >&2
  exit 3
}

# ── 2. 下载资产并校验 ───────────────────────────────────────────────────────
fetch "$DL_BASE/$UPSTREAM_REPO/releases/download/$TAG/$ASSET" "$CACHE_DIR/$TAG/$ASSET"
ACTUAL="$(sha256sum "$CACHE_DIR/$TAG/$ASSET" | awk '{print $1}')"
if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "sha256 不符：期望 $EXPECTED 实际 $ACTUAL（上游可能重传了资产，删缓存重试）" >&2
  exit 4
fi
log "sha256 校验通过（来源：release 元数据 digest）：$ACTUAL"

# ── 3. 解包并核对架构 ───────────────────────────────────────────────────────
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
tar -xzf "$CACHE_DIR/$TAG/$ASSET" -C "$WORK"

BIN="$WORK/pnpm"
[ -f "$BIN" ] || { echo "压缩包里没有 pnpm 可执行文件（实际内容：$(ls -A "$WORK" | tr '\n' ' ')）" >&2; exit 5; }

# ELF e_machine（偏移 18 字节，小端）：0xB7=aarch64，0x3E=x86-64
MACHINE="$(od -An -tx1 -j18 -N2 "$BIN" | tr -d ' \n')"
if [ "$MACHINE" != "$ELF_WANT" ]; then
  echo "ELF 架构与 ARCH=$ARCH 不符（e_machine=$MACHINE，期望 $ELF_WANT）" >&2
  exit 6
fi
log "ELF 架构核对通过：$ARCH ($MACHINE)"

# ── 4. 铺进 payload ─────────────────────────────────────────────────────────
# 官方 standalone 包里除了 pnpm 可执行文件，还带一个 dist/ 目录（node-gyp 及相关脚本）。
# 它必须和可执行文件**保持同级**：pnpm 在做 pnpm rebuild / 编译原生模块时按
# `dist/node_modules/node-gyp/bin/node-gyp.js` 这个相对位置去找它（二进制里能看到
# `node-gyp-bin` / `node-gyp.js` 这两个字符串）。少放这一层，纯 JS 项目照跑，
# 但带原生扩展的项目（node-sass、better-sqlite3 之类）会在 rebuild 阶段失败。
mkdir -p "$PAYLOAD_DIR/bin" "$PAYLOAD_DIR/share"
if [ -d "$WORK/dist" ]; then
  cp -a "$WORK/dist" "$PAYLOAD_DIR/bin/dist"
  log "已带上 dist/（node-gyp 等运行时资产）：$(du -sh "$PAYLOAD_DIR/bin/dist" | cut -f1)"
else
  log "警告：上游包里没有 dist/，pnpm rebuild 这类需要 node-gyp 的操作将不可用"
fi
install -m 0755 "$BIN" "$PAYLOAD_DIR/bin/pnpm"

# 许可证：压缩包里带了就用它的，没带就从同一 tag 的仓库取（MIT 再分发义务）
LICENSE_SRC=""
for f in LICENSE LICENSE.md LICENCE; do
  [ -f "$WORK/$f" ] && { LICENSE_SRC="$WORK/$f"; break; }
done
if [ -n "$LICENSE_SRC" ]; then
  install -m 0644 "$LICENSE_SRC" "$PAYLOAD_DIR/share/LICENSE"
  log "许可证取自压缩包：$LICENSE_SRC"
else
  fetch "$DL_BASE/$UPSTREAM_REPO/raw/$TAG/LICENSE" "$CACHE_DIR/$TAG/LICENSE"
  install -m 0644 "$CACHE_DIR/$TAG/LICENSE" "$PAYLOAD_DIR/share/LICENSE"
  log "许可证取自仓库 $TAG 的 LICENSE（压缩包内未附带）"
fi

BIN_SHA="$(sha256sum "$PAYLOAD_DIR/bin/pnpm" | awk '{print $1}')"

cat > "$PAYLOAD_DIR/share/PROVENANCE.json" <<EOF
{
  "app": "pnpm",
  "upstream_repo": "https://github.com/${UPSTREAM_REPO}",
  "upstream_tag": "${TAG}",
  "upstream_version": "${VERSION}",
  "license": "MIT",
  "source_author": "pnpm",
  "payload": {
    "kind": "prebuilt-standalone-binary",
    "asset": "${ASSET}",
    "asset_url": "${DL_BASE}/${UPSTREAM_REPO}/releases/download/${TAG}/${ASSET}",
    "asset_sha256": "${ACTUAL}",
    "asset_sha256_source": "github release asset digest",
    "binary": "bin/pnpm",
    "binary_sha256": "${BIN_SHA}",
    "arch": "${ARCH}",
    "elf_machine": "${MACHINE}",
    "note": "官方 standalone 构建：Node 引擎编译进 pnpm 可执行文件内部，运行时不依赖系统/应用中心的 nodejs 运行时；随包带上同级 dist/（node-gyp 等），rebuild 原生模块时按相对位置查找"
  },
  "packaged_by": "bekafka/FnDepot",
  "packaged_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
EOF

log "payload 就绪"
find "$PAYLOAD_DIR" -type f -printf '  %-52p %10s\n' | sort || true
