#!/usr/bin/env bash
# ==============================================================================
# gh · payload 生产线（载体：GitHub CLI 官方发布的 linux 静态产物）
#
# 由 FnFactory 的 _build-fpk.yml 或本仓库 build-local.sh 调用，只负责把产物
# 铺进 $PAYLOAD_DIR（= <workspace>/gh/app）。包里最终长这样：
#
#   app/bin/gh.real                     上游 bin/gh（Go 静态二进制）
#   app/bin/gh                          包装层：按需注入 GH_TOKEN（来自模板 app/gh-wrapper.sh）
#   app/gh-link.sh                      命令入口助手（模板里已有）
#   app/share/LICENSE                   MIT 许可证原文
#   app/share/PROVENANCE.json           版本 / 资产 sha256 / 二进制 sha256 / 下载地址
#
# 纪律（FnFactory specs + fnos-fpk-builder）：
#   · 取上游官方产物，不自己编译；
#   · gh 的 release **自带 checksums 清单**，校验值取自清单里对应那一行；
#     取不到就退出，绝不"记下实际值"；
#   · 解包后核对 ELF 架构，避免把 x86 产物塞进 arm 包；
#   · 包装层必须是 bin/gh（usr-local-linker 链的就是它），真实二进制叫 gh.real，
#     这样「token 自动注入」对所有用户生效，而不是只对某个账号生效。
# ==============================================================================
set -euo pipefail

ARCH="${ARCH:?ARCH is required (arm64|amd64)}"
VERSION="${VERSION:?VERSION is required (upstream tag without the leading v)}"
PAYLOAD_DIR="${PAYLOAD_DIR:?PAYLOAD_DIR is required}"

UPSTREAM_REPO="cli/cli"
TAG="v${VERSION}"
CACHE_DIR="${CACHE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.build/cache}"
# 国内环境/CI 可用 GH_DL_PROXY 指定代理；留空表示直连
PROXY="${GH_DL_PROXY:-}"
DL_BASE="${GH_DL_BASE:-https://github.com}"

log() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

case "$ARCH" in
  arm64) ASSET="gh_${VERSION}_linux_arm64.tar.gz" ; ELF_WANT="b700" ;;
  amd64) ASSET="gh_${VERSION}_linux_amd64.tar.gz" ; ELF_WANT="3e00" ;;
  *) echo "unsupported ARCH=$ARCH" >&2; exit 2 ;;
esac
CHECKSUMS="gh_${VERSION}_checksums.txt"

CURL=(curl -fsSL --retry 3 --retry-delay 2 --retry-connrefused -m 1200)
[ -n "$PROXY" ] && CURL+=(--proxy "$PROXY")

mkdir -p "$CACHE_DIR/$TAG"

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

BASE_URL="$DL_BASE/$UPSTREAM_REPO/releases/download/$TAG"

# ── 1. 取资产与上游校验清单 ─────────────────────────────────────────────────
fetch "$BASE_URL/$ASSET" "$CACHE_DIR/$TAG/$ASSET"
fetch "$BASE_URL/$CHECKSUMS" "$CACHE_DIR/$TAG/$CHECKSUMS"

EXPECTED="$(grep -E "[[:space:]]${ASSET}\$" "$CACHE_DIR/$TAG/$CHECKSUMS" | awk '{print $1}' | head -n 1)"
[ -n "$EXPECTED" ] || { echo "$CHECKSUMS 里没有 $ASSET 的校验值" >&2; exit 3; }
ACTUAL="$(sha256sum "$CACHE_DIR/$TAG/$ASSET" | awk '{print $1}')"
if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "sha256 不符：期望 $EXPECTED 实际 $ACTUAL（上游可能重传了资产，删缓存重试）" >&2
  exit 4
fi
log "sha256 校验通过（来源：上游 $CHECKSUMS）：$ACTUAL"

# ── 2. 解包并核对架构 ───────────────────────────────────────────────────────
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
tar -xzf "$CACHE_DIR/$TAG/$ASSET" -C "$WORK"

# 上游 tar 包内层带一层版本目录（gh_<ver>_linux_<arch>/bin/gh、.../share/man、.../LICENSE），
# 所以不能假设「解压根目录就是 bin/」——按结构查找，不写死目录名。
BIN="$(find "$WORK" -maxdepth 3 -type f -path '*/bin/gh' | head -n 1)"
[ -n "$BIN" ] || {
  echo "压缩包里找不到 */bin/gh（实际内容：$(find "$WORK" -maxdepth 3 | head -n 20 | tr '\n' ' ')）" >&2
  exit 5
}
GH_ROOT="$(dirname "$(dirname "$BIN")")"   # 含 bin/ 与 share/ 的那一层
echo "解包结构：GH_ROOT=$GH_ROOT"

# ELF e_machine（偏移 18 字节，小端）：0xB7=aarch64，0x3E=x86-64
MACHINE="$(od -An -tx1 -j18 -N2 "$BIN" | tr -d ' \n')"
if [ "$MACHINE" != "$ELF_WANT" ]; then
  echo "ELF 架构与 ARCH=$ARCH 不符（e_machine=$MACHINE，期望 $ELF_WANT）" >&2
  exit 6
fi
log "ELF 架构核对通过：$ARCH ($MACHINE)"

# ── 3. 铺进 payload ─────────────────────────────────────────────────────────
mkdir -p "$PAYLOAD_DIR/bin" "$PAYLOAD_DIR/share"
install -m 0755 "$BIN" "$PAYLOAD_DIR/bin/gh.real"

# 包装层：模板里的 app/gh-wrapper.sh 就是将来的 bin/gh
WRAPPER_SRC="$PAYLOAD_DIR/gh-wrapper.sh"
[ -f "$WRAPPER_SRC" ] || { echo "模板缺少 app/gh-wrapper.sh，无法生成命令入口包装" >&2; exit 7; }
install -m 0755 "$WRAPPER_SRC" "$PAYLOAD_DIR/bin/gh"
# 模板源文件只在构建期有用，不要留在 payload 里（否则包内会多一份同内容的 gh-wrapper.sh）
rm -f "$WRAPPER_SRC"
log "命令入口包装已就位：bin/gh（真实二进制 bin/gh.real）"

# 许可证（MIT 再分发义务）：压缩包里带了就用，没带就从同一 tag 的仓库取
LICENSE_SRC=""
for base in "$GH_ROOT" "$WORK"; do
  for f in LICENSE LICENSE.md LICENCE; do
    [ -f "$base/$f" ] && { LICENSE_SRC="$base/$f"; break 2; }
  done
done
if [ -n "$LICENSE_SRC" ]; then
  install -m 0644 "$LICENSE_SRC" "$PAYLOAD_DIR/share/LICENSE"
  log "许可证取自压缩包：$LICENSE_SRC"
else
  fetch "$DL_BASE/$UPSTREAM_REPO/raw/$TAG/LICENSE" "$CACHE_DIR/$TAG/LICENSE"
  install -m 0644 "$CACHE_DIR/$TAG/LICENSE" "$PAYLOAD_DIR/share/LICENSE"
  log "许可证取自仓库 $TAG 的 LICENSE（压缩包内未附带）"
fi

BIN_SHA="$(sha256sum "$PAYLOAD_DIR/bin/gh.real" | awk '{print $1}')"

cat > "$PAYLOAD_DIR/share/PROVENANCE.json" <<EOF
{
  "app": "gh-cli",
  "upstream_repo": "https://github.com/${UPSTREAM_REPO}",
  "upstream_tag": "${TAG}",
  "upstream_version": "${VERSION}",
  "license": "MIT",
  "source_author": "cli",
  "payload": {
    "kind": "prebuilt-release-binary",
    "asset": "${ASSET}",
    "asset_url": "${BASE_URL}/${ASSET}",
    "asset_sha256": "${ACTUAL}",
    "asset_sha256_source": "upstream ${CHECKSUMS}",
    "binary": "bin/gh.real",
    "binary_sha256": "${BIN_SHA}",
    "wrapper": "bin/gh",
    "arch": "${ARCH}",
    "elf_machine": "${MACHINE}",
    "note": "上游 Go 静态二进制；bin/gh 是本地包装层，负责把安装向导里填的 token 以 GH_TOKEN 注入"
  },
  "packaged_by": "bekafka/FnDepot",
  "packaged_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
EOF

log "payload 就绪"
find "$PAYLOAD_DIR" -type f -printf '  %-52p %10s\n' | sort || true
