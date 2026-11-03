#!/usr/bin/env bash
# ==============================================================================
# PhotoCraft · payload 生产线
#
# 由 FnFactory 的 _build-fpk.yml 或本仓库 build-local.sh 调用，只负责把产物
# 铺进 $PAYLOAD_DIR（= <workspace>/PhotoCraft/app）。包里最终长这样：
#
#   app/bin/photocraft-web        从仓库内 apps/PhotoCraft/src 编出来的静态宿主（双架构）
#   app/webroot/                  上游官方 Web 包解包后的站点（已打 snippets 补丁 + 中文字体）
#   app/ui/...                    模板自带（桌面入口与图标）
#   app/share/PROVENANCE.json     上游版本 / 站点摘要 / 字体摘要 / 二进制摘要 / 工具链
#
# 载体判断（fnos-fpk-porting 三选一）：上游已发 WebAssembly 静态站点包 → 取预编译产物，
# 不自己编 wasm（本机 3.6GB 级设备也编不动、且官方产物带 fat LTO 与 wasm-opt）。
# 我们只编那层极薄的「静态宿主」，纯标准库 Go，CGO_ENABLED=0，交叉编译零依赖。
#
# 纪律：
#   · 上游 zip 与字体都按固定 sha256 校验，不信任「下载成功了」；
#   · snippets 补丁必须幂等（上游发新版重跑时不能叠出 app/snippets/snippets）；
#   · 编完核对 ELF 架构，避免把 amd64 塞进 arm 包；
#   · 二进制在包里必须可执行（0755），飞牛安装时不一定替我们补位。
# ==============================================================================
set -euo pipefail

ARCH="${ARCH:?ARCH is required (arm64|amd64)}"
VERSION="${VERSION:?VERSION is required（包版本，例 0.20.1 或 0.20.1-2）}"
PAYLOAD_DIR="${PAYLOAD_DIR:?PAYLOAD_DIR is required}"
PLATFORM="${PLATFORM:-}"

APP_KEY="PhotoCraft"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/src"
CACHE="${PHOTOCRAFT_CACHE_DIR:-$ROOT/packaging/.cache}"
STAGE="$CACHE/stage"
BIN="$PAYLOAD_DIR/bin/photocraft-web"

# ── 上游工件（钉版本 + 钉 sha256）─────────────────────────────────────────────
UPSTREAM_VERSION="${PHOTOCRAFT_UPSTREAM_VERSION:-0.20.1}"
WEB_ZIP_SHA256="${PHOTOCRAFT_WEB_ZIP_SHA256:-3fb515524008cfdd38d088f983d773b7ee35ad32b5710da8e94fc72507515260}"
WEB_ZIP_URL="${PHOTOCRAFT_WEB_ZIP_URL:-https://github.com/storytold/photocraft/releases/download/v${UPSTREAM_VERSION}/photocraft-web-${UPSTREAM_VERSION}.zip}"

# 中文字体：取自上游 craft-fonts（OFL，Hans 覆盖），sha256 与它自己的 manifest 一致
FONT_REL="fonts/noto-sans-cjk-sc/NotoSansCJKsc-Regular.otf"
FONT_FAMILY="Noto Sans CJK SC"
FONT_SHA256="${PHOTOCRAFT_FONT_SHA256:-2c76254f6fc379fddfce0a7e84fb5385bb135d3e399294f6eeb6680d0365b74b}"
FONT_URL="${PHOTOCRAFT_FONT_URL:-https://raw.githubusercontent.com/storytold/craft-fonts/main/$FONT_REL}"
OFL_URL="https://raw.githubusercontent.com/storytold/craft-fonts/main/fonts/noto-sans-cjk-sc/OFL.txt"

log() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

case "$ARCH" in
  arm64|amd64) ;;
  *) die "unsupported ARCH=$ARCH" ;;
esac
: "${PLATFORM:=$([ "$ARCH" = arm64 ] && echo arm || echo x86)}"

BASE_VERSION="$(printf '%s' "$VERSION" | sed -E 's/-[0-9]+$//')"
mkdir -p "$CACHE" "$PAYLOAD_DIR/bin" "$PAYLOAD_DIR/share"

# ── 1. 取上游 Web 包并校验 ───────────────────────────────────────────────────
log "上游 Web 包：$UPSTREAM_VERSION"
if [ -n "${PHOTOCRAFT_WEB_ZIP:-}" ]; then
  WEB_ZIP="$PHOTOCRAFT_WEB_ZIP"
  log "使用本地指定的 zip：$WEB_ZIP"
else
  WEB_ZIP="$CACHE/photocraft-web-${UPSTREAM_VERSION}.zip"
  if [ ! -s "$WEB_ZIP" ]; then
    log "下载 $WEB_ZIP_URL"
    curl -fL --retry 3 --connect-timeout 15 -o "$WEB_ZIP.tmp" "$WEB_ZIP_URL" || die "下载上游 Web 包失败"
    mv "$WEB_ZIP.tmp" "$WEB_ZIP"
  else
    log "命中本地缓存：$WEB_ZIP"
  fi
fi
ACTUAL="$(sha256sum "$WEB_ZIP" | awk '{print $1}')"
[ "$ACTUAL" = "$WEB_ZIP_SHA256" ] || die "上游 Web 包 sha256 不符：期望 $WEB_ZIP_SHA256，实际 $ACTUAL"
log "sha256 校验通过"

# ── 2. 解包 + snippets 补丁（幂等）───────────────────────────────────────────
log "解包与修补"
rm -rf "$STAGE"
mkdir -p "$STAGE"
unzip -q "$WEB_ZIP" -d "$STAGE"
SITE="$(find "$STAGE" -maxdepth 1 -mindepth 1 -type d -name 'photocraft-web-*' | head -n 1)"
[ -n "$SITE" ] && [ -f "$SITE/index.html" ] || die "解包后找不到站点目录（index.html 缺失）"

# 上游自 0.17 起的打包缺陷（issue #10491）：app/photocraft-web.js 里
# `import … from "./snippets/eframe-<hash>/inline0.js"` 是相对胶水自身目录解析的，
# 而 zip 只把 snippets/ 放在解包根，于是浏览器在 /app/snippets/… 上吃 404，
# 页面永久停在 Loading。补法就是把根 snippets 复制进 app/（幂等，可随升级重放）。
if [ -d "$SITE/snippets" ]; then
  mkdir -p "$SITE/app"
  cp -a "$SITE/snippets/." "$SITE/app/snippets/"
  log "已修补 snippets → app/snippets（上游 #10491）"
else
  log "注意：包内没有 snippets/，跳过修补（上游可能已修）"
fi
# 复查：胶水若引用 snippets，则 app/snippets 必须存在
if grep -q 'snippets/' "$SITE/app/photocraft-web.js" 2>/dev/null && [ ! -d "$SITE/app/snippets" ]; then
  die "胶水引用了 snippets/，但 app/snippets 不存在——补丁没成功，打出来的包会卡在加载页"
fi

# ── 3. 中文字体（浏览器不给系统字体，必须随站点自带）──────────────────────────
log "中文字体：$FONT_FAMILY"
FONT_LOCAL="$CACHE/NotoSansCJKsc-Regular.otf"
if [ ! -s "$FONT_LOCAL" ]; then
  curl -fL --retry 3 --connect-timeout 15 -o "$FONT_LOCAL.tmp" "$FONT_URL" || die "下载中文字体失败"
  mv "$FONT_LOCAL.tmp" "$FONT_LOCAL"
fi
FACTUAL="$(sha256sum "$FONT_LOCAL" | awk '{print $1}')"
[ "$FACTUAL" = "$FONT_SHA256" ] || die "字体 sha256 不符：期望 $FONT_SHA256，实际 $FACTUAL"
mkdir -p "$SITE/fonts/noto-sans-cjk-sc"
cp "$FONT_LOCAL" "$SITE/$FONT_REL"
curl -fsSL --retry 3 -o "$SITE/fonts/noto-sans-cjk-sc/OFL.txt" "$OFL_URL" || die "下载字体许可证失败"
cat > "$SITE/fonts/manifest.txt" <<EOF
# PhotoCraft 站点自带字体清单
# 字段：family | style | file（相对站点根）| scripts | licence | licence file | sha256 | source
# 应用只读前三个字段；family 必须是字体自己的家族名（字体菜单里显示的就是它）。
${FONT_FAMILY} | Regular | ${FONT_REL} | Hans,Latn | OFL-1.1 | fonts/noto-sans-cjk-sc/OFL.txt | ${FONT_SHA256} | https://github.com/notofonts/noto-cjk
EOF
log "字体与 manifest 就位"

# ── 4. 铺站点到 payload ─────────────────────────────────────────────────────
log "铺站点"
rm -rf "$PAYLOAD_DIR/webroot"
mkdir -p "$PAYLOAD_DIR/webroot"
cp -a "$SITE/." "$PAYLOAD_DIR/webroot/"
# 打包平台的示例配置对我们没用（我们的服务自己写响应头），清掉以免误导
rm -f "$PAYLOAD_DIR/webroot/_headers" "$PAYLOAD_DIR/webroot/.htaccess"
SITE_FILES="$(find "$PAYLOAD_DIR/webroot" -type f | wc -l)"
SITE_BYTES="$(du -sb "$PAYLOAD_DIR/webroot" | awk '{print $1}')"
SITE_SHA="$(cd "$PAYLOAD_DIR/webroot" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')"
log "站点：$SITE_FILES 个文件，$SITE_BYTES 字节，内容摘要 $SITE_SHA"

# ── 5. 编静态宿主 ───────────────────────────────────────────────────────────
command -v go >/dev/null 2>&1 || die "需要 go 工具链（>= 1.21）"
[ -f "$SRC/go.mod" ] || die "缺少 $SRC/go.mod"
# 只读构建：没有外部依赖，不写 go.sum；GOTOOLCHAIN=local 避免联网拉工具链。
export GOTOOLCHAIN="${GO_TOOLCHAIN:-local}"
log "go build linux/$ARCH（$(go version)）"
(
  cd "$SRC"
  env -u GOFLAGS CGO_ENABLED=0 GOOS=linux GOARCH="$ARCH" GOTOOLCHAIN="$GOTOOLCHAIN" \
    go build -trimpath -buildvcs=false \
      -ldflags "-s -w -X main.version=${BASE_VERSION}" \
      -o "$BIN" .
)
chmod 0755 "$BIN"
[ -s "$BIN" ] || die "构建产物为空：$BIN"

# ELF e_machine（偏移 18 字节，小端）：0xB7=aarch64，0x3E=x86-64
MACHINE="$(od -An -tx1 -j18 -N2 "$BIN" | tr -d ' \n')"
case "$ARCH:$MACHINE" in
  arm64:b700) ;;
  amd64:3e00) ;;
  *) die "ELF 架构与 ARCH=$ARCH 不符（e_machine=$MACHINE）" ;;
esac
log "ELF 架构核对通过：$ARCH ($MACHINE)"

# ── 6. 溯源 ────────────────────────────────────────────────────────────────
BIN_SHA="$(sha256sum "$BIN" | awk '{print $1}')"
cat > "$PAYLOAD_DIR/share/PROVENANCE.json" <<EOF
{
  "app": "${APP_KEY}",
  "project": "https://github.com/bekafka/FnDepot/tree/main/apps/${APP_KEY}",
  "package_version": "${VERSION}",
  "upstream": {
    "project": "https://github.com/storytold/photocraft",
    "version": "${UPSTREAM_VERSION}",
    "artifact": "photocraft-web-${UPSTREAM_VERSION}.zip",
    "artifact_sha256": "${WEB_ZIP_SHA256}",
    "site_files": ${SITE_FILES},
    "site_bytes": ${SITE_BYTES},
    "site_content_sha256": "${SITE_SHA}",
    "local_patch": "app/snippets ← snippets（修上游 issue #10491 的自托管 404，幂等）",
    "fonts_added": ["${FONT_FAMILY} Regular (OFL-1.1, sha256 ${FONT_SHA256})"]
  },
  "payload": {
    "kind": "upstream-static-web-bundle + built-static-host",
    "binary": "bin/photocraft-web",
    "binary_sha256": "${BIN_SHA}",
    "arch": "${ARCH}",
    "platform": "${PLATFORM}",
    "elf_machine": "${MACHINE}",
    "build_flags": "CGO_ENABLED=0 GOOS=linux -trimpath -ldflags=-s -w",
    "note": "宿主是纯 Go 标准库静态服务，只发文件；不写盘、不代理、无服务端存储"
  },
  "packaged_by": "bekafka/FnDepot",
  "packaged_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
EOF

log "payload 就绪"
find "$PAYLOAD_DIR" -maxdepth 2 -type d | sort
du -sh "$PAYLOAD_DIR"
