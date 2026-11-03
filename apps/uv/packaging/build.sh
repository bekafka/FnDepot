#!/usr/bin/env bash
# ==============================================================================
# uv · payload 生产线（载体：uv 官方「单文件可执行」release 资产）
#
# 由 FnFactory 的 _build-fpk.yml 或本仓库 build-local.sh 调用，只负责把产物
# 铺进 $PAYLOAD_DIR（= <workspace>/uv/app）。包里最终长这样：
#
#   app/bin/uv                          官方独立可执行文件（Rust 静态编译，无运行时依赖）
#   app/bin/uvx                         uv tool run 的别名入口（官方包自带；缺则建同名软链）
#   app/uv-link.sh                      命令入口助手（模板里已有，不经本脚本）
#   app/share/LICENSE-APACHE|LICENSE-MIT  双许可原文（再分发义务）
#   app/share/PROVENANCE.json           版本 / 资产 sha256 / 二进制 sha256 / 下载地址
#
# 与 pnpm 包的两处关键差异：
#   1. **uv 的 tag 不带 v 前缀**（0.13.7，不是 v0.13.7），所以 TAG="${VERSION}"；
#   2. **uv 的 Linux 资产是目标三元组命名**（uv-x86_64-unknown-linux-gnu.tar.gz），
#      不是 pnpm 那种 pnpm-linux-x64 口径，映射写死在下面对照表里，不靠猜；
#      另有 musl 口味，这里固定取 gnu（目标机 glibc 2.36 满足）。
#   3. **除了压缩包自带的 sha256 摘要，上游还单独发 .sha256 文件**：优先用上游
#      那份校验文件比对；取不到再退回 release 元数据里的 digest。两个都拿不到就中止。
# ==============================================================================
set -euo pipefail

ARCH="${ARCH:?ARCH is required (arm64|amd64)}"
VERSION="${VERSION:?VERSION is required (upstream tag; uv 的 tag 不带 v)}"
PAYLOAD_DIR="${PAYLOAD_DIR:?PAYLOAD_DIR is required}"

UPSTREAM_REPO="astral-sh/uv"
TAG="${VERSION}"                     # uv 的 tag 本身就是版本号
CACHE_DIR="${CACHE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.build/cache}"
PROXY="${UV_DL_PROXY:-}"
API_BASE="${UV_API_BASE:-https://api.github.com}"
DL_BASE="${UV_DL_BASE:-https://github.com}"

log() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

case "$ARCH" in
  arm64) TARGET="aarch64-unknown-linux-gnu"; ELF_WANT="b700" ;;
  amd64) TARGET="x86_64-unknown-linux-gnu" ; ELF_WANT="3e00" ;;
  *) echo "unsupported ARCH=$ARCH" >&2; exit 2 ;;
esac
ASSET="uv-${TARGET}.tar.gz"

CURL=(curl -fsSL --retry 3 --retry-delay 2 --retry-connrefused -m 1200)
[ -n "$PROXY" ] && CURL+=(--proxy "$PROXY")

mkdir -p "$CACHE_DIR/$VERSION"

fetch() { # $1=url $2=dest  （失败返回非零，不中断脚本，由调用方决定是否致命）
  local url="$1" dest="$2"
  if [ -s "$dest" ]; then
    log "缓存命中：$(basename "$dest")"
    return 0
  fi
  rm -f "$dest.part"
  log "下载 $url"
  if "${CURL[@]}" -o "$dest.part" "$url" 2>/dev/null; then
    mv -f "$dest.part" "$dest"
    return 0
  fi
  rm -f "$dest.part"
  return 1
}

# ── 1. 校验来源：优先上游 .sha256 文件，其次 release 元数据 digest ───────────
EXPECTED=""
if fetch "$DL_BASE/$UPSTREAM_REPO/releases/download/$TAG/$ASSET.sha256" "$CACHE_DIR/$VERSION/$ASSET.sha256"; then
  # 上游格式是「<hash>  <文件名>」，也可能只有 hash
  EXPECTED="$(awk 'NR==1{print $1}' "$CACHE_DIR/$VERSION/$ASSET.sha256" | tr -d '[:space:]')"
  [ -n "$EXPECTED" ] && log "校验源：上游 $ASSET.sha256 文件"
fi
if [ -z "$EXPECTED" ]; then
  META="$CACHE_DIR/$VERSION/release.json"
  fetch "$API_BASE/repos/$UPSTREAM_REPO/releases/tags/$TAG" "$META" || true
  EXPECTED="$(ASSET="$ASSET" python3 - "$META" <<'PY' 2>/dev/null || true
import json, os, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(0)
for a in data.get("assets", []):
    if a.get("name") == os.environ["ASSET"]:
        d = a.get("digest") or ""
        if d.startswith("sha256:"):
            print(d.split(":", 1)[1])
        break
PY
)"
  [ -n "$EXPECTED" ] && log "校验源：release 元数据 digest"
fi
[ -n "$EXPECTED" ] || {
  echo "拿不到 $ASSET 的校验值（.sha256 与元数据 digest 都失败），停止打包" >&2
  exit 3
}

# ── 2. 下载资产并校验 ───────────────────────────────────────────────────────
fetch "$DL_BASE/$UPSTREAM_REPO/releases/download/$TAG/$ASSET" "$CACHE_DIR/$VERSION/$ASSET"
ACTUAL="$(sha256sum "$CACHE_DIR/$VERSION/$ASSET" | awk '{print $1}')"
if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "sha256 不符：期望 $EXPECTED 实际 $ACTUAL（上游可能重传了资产，删缓存重试）" >&2
  exit 4
fi
log "sha256 校验通过：$ACTUAL"

# ── 3. 解包、找可执行文件、核对架构 ─────────────────────────────────────────
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
tar -xzf "$CACHE_DIR/$VERSION/$ASSET" -C "$WORK"

BIN_UV="$(find "$WORK" -type f -name uv -perm -u+x -print -quit 2>/dev/null || true)"
[ -n "$BIN_UV" ] || { echo "压缩包里没有 uv 可执行文件（实际内容：$(find "$WORK" -maxdepth 2 -type f | head -5 | tr '\n' ' ')）" >&2; exit 5; }

MACHINE="$(od -An -tx1 -j18 -N2 "$BIN_UV" | tr -d ' \n')"
if [ "$MACHINE" != "$ELF_WANT" ]; then
  echo "ELF 架构与 ARCH=$ARCH 不符（e_machine=$MACHINE，期望 $ELF_WANT）" >&2
  exit 6
fi
log "ELF 架构核对通过：$ARCH ($MACHINE)"

BIN_UVX="$(find "$WORK" -type f -name uvx -print -quit 2>/dev/null || true)"

# ── 4. 铺进 payload ─────────────────────────────────────────────────────────
mkdir -p "$PAYLOAD_DIR/bin" "$PAYLOAD_DIR/share"
install -m 0755 "$BIN_UV" "$PAYLOAD_DIR/bin/uv"
if [ -n "$BIN_UVX" ]; then
  install -m 0755 "$BIN_UVX" "$PAYLOAD_DIR/bin/uvx"
  log "已带上 uvx（官方包自带）"
else
  # uvx 只是 uv tool run 的别名入口，按 argv[0] 分派；上游没带时用同名软链补齐，
  # 这样命令入口声明的两条命令都能落地，不会因为缺文件让平台链接失败。
  ln -sfn uv "$PAYLOAD_DIR/bin/uvx"
  log "上游包未附 uvx：已建立 bin/uvx → uv 软链（uv 按 argv[0] 分派，行为等价）"
fi

# 许可证：双许可（MIT OR Apache-2.0），从同一 tag 的仓库取两份原文
for f in LICENSE-APACHE LICENSE-MIT; do
  if fetch "$DL_BASE/$UPSTREAM_REPO/raw/$TAG/$f" "$CACHE_DIR/$VERSION/$f"; then
    install -m 0644 "$CACHE_DIR/$VERSION/$f" "$PAYLOAD_DIR/share/$f"
  else
    echo "::warning::取不到 $f（不影响出包，但再分发许可文本不完整）" >&2
  fi
done

BIN_SHA="$(sha256sum "$PAYLOAD_DIR/bin/uv" | awk '{print $1}')"

cat > "$PAYLOAD_DIR/share/PROVENANCE.json" <<EOF
{
  "app": "uv",
  "upstream_repo": "https://github.com/${UPSTREAM_REPO}",
  "upstream_tag": "${TAG}",
  "upstream_version": "${VERSION}",
  "license": "MIT OR Apache-2.0",
  "source_author": "astral-sh",
  "payload": {
    "kind": "prebuilt-standalone-binary",
    "asset": "${ASSET}",
    "asset_url": "${DL_BASE}/${UPSTREAM_REPO}/releases/download/${TAG}/${ASSET}",
    "asset_sha256": "${ACTUAL}",
    "binary": "bin/uv",
    "binary_sha256": "${BIN_SHA}",
    "second_binary": "bin/uvx",
    "arch": "${ARCH}",
    "target_triple": "${TARGET}",
    "elf_machine": "${MACHINE}",
    "note": "官方 Rust 静态构建：uv 自带包管理与 Python 版本管理能力，运行时不依赖系统 Python/pip；Linux 取 gnu 口味（目标机 glibc 2.36 满足）"
  },
  "packaged_by": "${UPSTREAM_REPO}",
  "packaged_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
EOF

log "payload 就绪"
find "$PAYLOAD_DIR" -type f -printf '  %-52p %10s\n' | sort || true
ls -l "$PAYLOAD_DIR/bin" || true
