#!/usr/bin/env bash
# ==============================================================================
# Motrix Server payload 生产（零编译）
#
# 由 fpk-factory 的 _build-fpk.yml 调用，入参：
#   ARCH         amd64 | arm64
#   PLATFORM     x86 | arm            （本脚本只用到它在报错信息里）
#   VERSION      包版本，同时是上游 tag（v<VERSION>）与镜像 tag
#   PAYLOAD_DIR  产物落点，最终成为 fpk 里的 app/
#
# 这条流水线做四件事，全部是文件操作，不做任何编译：
#   ① 从官方 Docker 镜像里取出"上游已构建好的 server-app 产物"（JS/Web/legal/builtin 插件）
#   ② 用上游自己的 scripts/stage-server-app.mjs 针对 glibc 重新 stage 一次
#      —— 这一步会把 better-sqlite3 的 musl prebuild 换成 glibc prebuild
#   ③ 用上游自己的 scripts/verify-server-package.mjs 验收（架构/原生件/体积/externals/清单指纹）
#   ④ 放进 $PAYLOAD_DIR/server
#
# 为什么可信：JS 产物来自官方镜像（同 tag、同一套 CI）；平台相关的只有三个原生件
#   better-sqlite3 / aria2c / motrix-finalize-fs，前者的 glibc 版本由 npm 包自带，
#   后两者在 linux-arm64 上本来就是静态链接（与 libc 无关）。
# ==============================================================================
set -euo pipefail

ARCH="${ARCH:?ARCH is required (amd64|arm64)}"
PLATFORM="${PLATFORM:-}"
VERSION="${VERSION:?VERSION is required}"
PAYLOAD_DIR="${PAYLOAD_DIR:?PAYLOAD_DIR is required}"

case "$ARCH" in
  arm64) IMAGE_ARCH="arm64"; NODE_ARCH="arm64" ;;
  amd64) IMAGE_ARCH="amd64"; NODE_ARCH="x64" ;;
  *) echo "unsupported ARCH=$ARCH" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"   # 应用根（apps/Motrix）；.build 缓存放这里
MOTRIX_GIT="${MOTRIX_GIT:-https://github.com/agalwood/Motrix}"
MOTRIX_IMAGE="${MOTRIX_IMAGE:-motrixapp/motrix-server}"
NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmjs.org/}"
WORK="${MOTRIX_BUILD_WORK:-$REPO_ROOT/.build}"
SRC="$WORK/src-$VERSION"
IMAGE_DIR="$WORK/image-$IMAGE_ARCH"
export NPM_CONFIG_REGISTRY="$NPM_REGISTRY"

log() { printf '\n\033[1m== [%s] %s\033[0m\n' "$(date +%H:%M:%S)" "$*"; }

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing required tool: $1" >&2; exit 3; }
}
require git
require node
require python3
node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 20 ? 0 : 1)' \
  || { echo "node >= 20 is required (staging helper)" >&2; exit 3; }

mkdir -p "$WORK"

# ── ① 取官方镜像里的上游产物 ────────────────────────────────────────────────────
if [ ! -f "$IMAGE_DIR/app/dist/server/index.mjs" ]; then
  log "extracting $MOTRIX_IMAGE:$VERSION (linux/$IMAGE_ARCH) from registry"
  python3 "$SCRIPT_DIR/tools/oci-extract.py" \
    --repo "$MOTRIX_IMAGE" --tag "$VERSION" --arch "$IMAGE_ARCH" --outdir "$IMAGE_DIR"
else
  log "reusing cached image extract at $IMAGE_DIR"
fi

APP_JSON="$IMAGE_DIR/app/package.json"
[ -f "$APP_JSON" ] || { echo "image extract has no /app/package.json" >&2; exit 4; }
IMAGE_VERSION="$(node -e "process.stdout.write(require('$APP_JSON').version)")"
[ "$IMAGE_VERSION" = "$VERSION" ] || {
  echo "image version mismatch: image=$IMAGE_VERSION expected=$VERSION" >&2; exit 4; }
log "image app version = $IMAGE_VERSION"

# ── ② 检出上游源码（stage/verify 脚本所在） ─────────────────────────────────────
if [ ! -d "$SRC/.git" ]; then
  log "cloning $MOTRIX_GIT @ v$VERSION"
  rm -rf "$SRC"
  git clone --depth 1 --branch "v$VERSION" "$MOTRIX_GIT" "$SRC"
else
  log "reusing source checkout at $SRC"
fi
cd "$SRC"

if command -v pnpm >/dev/null 2>&1; then
  PNPM=pnpm
elif command -v corepack >/dev/null 2>&1; then
  PNPM="corepack pnpm"
else
  echo "pnpm (or corepack) is required" >&2; exit 3
fi

log "pnpm install --prod --ignore-scripts (runtime closure only)"
# 只用生产依赖：stage 脚本按 require 图解析运行时依赖，不需要 dev 依赖/Electron。
# 注意 registry：npmmirror 缺 @motrix/nat@0.1.4，会 404。
$PNPM install --prod --ignore-scripts --frozen-lockfile --registry="$NPM_REGISTRY"

log "fetching aria2 engine for linux-$NODE_ARCH (verified against scripts/engine.lock.json)"
node scripts/fetch-engine.mjs --platform linux --arch "$NODE_ARCH"

# ── ②b fnOS 兼容补丁：finalize-fs 的 O_PATH 回退 ────────────────────────────────
# 上游 open_root 从 / 逐级 open(O_RDONLY|O_DIRECTORY)；飞牛 fnOS 的内核 trimacl 层
# 只允许应用用户"穿过"数据卷根目录（/vol1 可执行不可读）→ 下载完成后的改名收尾
# 必报 open_root: Permission denied。补丁让它对不可读的中间目录回退 O_PATH
# （O_PATH 描述符足以支撑后续 openat/renameat2/linkat/statx），最终目录仍优先用
# 可读句柄打开，因此普通系统上的行为完全不变。
FINALIZE_PATCH="$SCRIPT_DIR/patches/finalize-fs-open-root-o_path.patch"
RUST_IMAGE="${RUST_IMAGE:-rust:1.94.1-alpine}"
FINALIZE_BIN_OVERRIDE="${MOTRIX_FINALIZE_FS_BIN:-}"

if [ -n "$FINALIZE_BIN_OVERRIDE" ]; then
  # 逃生口：本机没有能跑目标架构的容器运行时（例如 x86_64 上打 arm64 包）时，
  # 直接用别处构建好的、同样打过补丁的二进制。
  log "using prebuilt motrix-finalize-fs: $FINALIZE_BIN_OVERRIDE"
  [ -x "$FINALIZE_BIN_OVERRIDE" ] || { echo "MOTRIX_FINALIZE_FS_BIN is not executable" >&2; exit 6; }
else
  log "applying fnOS compatibility patch to packages/finalize-fs"
  if git apply --check "$FINALIZE_PATCH" 2>/dev/null; then
    git apply "$FINALIZE_PATCH"
    log "patch applied"
  elif git apply --reverse --check "$FINALIZE_PATCH" 2>/dev/null; then
    log "patch already applied"
  else
    echo "packaging/patches/finalize-fs-open-root-o_path.patch does not apply cleanly" >&2
    exit 5
  fi

  log "building patched motrix-finalize-fs for linux/$IMAGE_ARCH inside $RUST_IMAGE"
  CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-$(command -v docker || command -v podman || true)}"
  [ -n "$CONTAINER_RUNTIME" ] || {
    echo "需要 docker 或 podman 来构建打过补丁的 motrix-finalize-fs（或设置 MOTRIX_FINALIZE_FS_BIN 指向已构建好的二进制）" >&2
    exit 6
  }
  "$CONTAINER_RUNTIME" run --rm --platform "linux/$IMAGE_ARCH" \
    -v "$SRC/packages/finalize-fs:/src" -w /src \
    -e CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-2}" -e CARGO_TERM_COLOR=never \
    "$RUST_IMAGE" cargo build --release --locked
  FINALIZE_BIN_OVERRIDE="$SRC/packages/finalize-fs/target/release/motrix-finalize-fs"
  [ -x "$FINALIZE_BIN_OVERRIDE" ] || { echo "patched motrix-finalize-fs was not produced" >&2; exit 6; }
fi

# ── ③ 把镜像里的上游产物放回上游契约要求的位置 ──────────────────────────────────
log "installing upstream-built artifacts from the image into the checkout"
rm -rf dist/server dist/renderer-web dist/builtin-plugins dist/core/plugin/host
mkdir -p dist/core/plugin/host build/legal/server "packages/finalize-fs/dist/linux-$NODE_ARCH"
cp -a "$IMAGE_DIR/app/dist/server" dist/
cp -a "$IMAGE_DIR/app/dist/renderer-web" dist/
cp -a "$IMAGE_DIR/app/dist/core/plugin/host/quick-js-worker.cjs" dist/core/plugin/host/
cp -a "$IMAGE_DIR/app/builtin-plugins" dist/builtin-plugins
cp -a "$IMAGE_DIR/app/legal/." build/legal/server/
cp -a "$FINALIZE_BIN_OVERRIDE" "packages/finalize-fs/dist/linux-$NODE_ARCH/motrix-finalize-fs"
chmod 0755 "packages/finalize-fs/dist/linux-$NODE_ARCH/motrix-finalize-fs" "extra/linux/$NODE_ARCH/aria2c"

# ── ③b operator 口令鉴权（默认关闭：个人局域网使用，不想每次填口令） ────────────
# AUTH_MODE=open   → 解锁页消失，/rpc/* 与 /api/* 对能访问该端口的人开放
# AUTH_MODE=token  → 保持上游默认（首启填 /vol1/@appdata/Motrix/data/operator-token）
AUTH_MODE="${AUTH_MODE:-open}"
export AUTH_MODE
case "$AUTH_MODE" in
  open)
    log "disabling operator token gate (AUTH_MODE=open)"
    node "$SCRIPT_DIR/tools/disable-operator-auth.mjs" dist/server/index.mjs
    ;;
  token)
    log "keeping upstream operator token gate (AUTH_MODE=token)"
    ;;
  *)
    echo "AUTH_MODE must be open or token" >&2; exit 7 ;;
esac

# 解锁页文案里带着 MOTRIX_OPERATOR_TOKEN 的提示（上游前端写死的 26 种语言）——
# 只有在保留口令模式时才有意义；AUTH_MODE=open 时解锁页根本不会出现。
if [ "$AUTH_MODE" = "token" ]; then
  log "patching renderer unlock hint (remove MOTRIX_OPERATOR_TOKEN mention)"
  node "$SCRIPT_DIR/tools/patch-renderer-hint.mjs" dist/renderer-web
fi

# ── ④ 重新 stage 成 glibc 目标 + 上游校验器验收 ─────────────────────────────────
log "staging server app for linux-$ARCH-gnu"
MOTRIX_SERVER_FINALIZE_FS_PREBUILT=1 node scripts/stage-server-app.mjs \
  --platform linux --arch "$ARCH" --libc gnu --strict

log "verifying staged server app with upstream verifier"
node scripts/verify-server-package.mjs \
  --app-dir dist/server-app --platform linux --arch "$ARCH" --libc gnu

# ── ⑤ 放进 payload ─────────────────────────────────────────────────────────────
log "copying staged app into payload: $PAYLOAD_DIR/server"
rm -rf "$PAYLOAD_DIR/server"
mkdir -p "$PAYLOAD_DIR"
cp -a dist/server-app "$PAYLOAD_DIR/server"
chmod 0755 "$PAYLOAD_DIR/server/bin/aria2c" "$PAYLOAD_DIR/server/bin/motrix-finalize-fs"

DIGEST_FILE="$IMAGE_DIR.digest"
node -e '
const fs = require("fs");
const path = require("path");
const [payloadDir, digestFile, version, arch, platform] = process.argv.slice(1);
const digest = fs.existsSync(digestFile) ? JSON.parse(fs.readFileSync(digestFile, "utf8")) : {};
const stage = JSON.parse(fs.readFileSync(path.join(payloadDir, "server", ".motrix-server-stage.json"), "utf8"));
const provenance = {
  app: "Motrix",
  upstream: "https://github.com/agalwood/Motrix",
  version,
  target: stage.target,
  arch,
  platform,
  source_image: digest.repo ? `${digest.repo}:${digest.tag}` : null,
  source_image_manifest_digest: digest.manifest_digest ?? null,
  staged_with: "scripts/stage-server-app.mjs --libc gnu (upstream)",
  verified_with: "scripts/verify-server-package.mjs --libc gnu (upstream)",
  aria2: "motrixapp/aria2 v1.37.0-motrix.17 (sha256 pinned in scripts/engine.lock.json)",
  finalize_fs:
    "built from upstream source + packaging/patches/finalize-fs-open-root-o_path.patch (O_PATH fallback for fnOS trimacl)",
  operator_auth:
    process.env.AUTH_MODE === "token"
      ? "upstream token gate (operator-token)"
      : "disabled via packaging/tools/disable-operator-auth.mjs (no unlock prompt; /rpc and /api are open to anyone reaching the port)",
  package_bytes: stage.inventory?.bytes ?? null,
  package_files: stage.inventory?.files ?? null,
};
fs.writeFileSync(path.join(payloadDir, "PROVENANCE.json"), JSON.stringify(provenance, null, 2) + "\n");
fs.writeFileSync(
  path.join(payloadDir, "AUTH_MODE"),
  (process.env.AUTH_MODE === "token" ? "token" : "open") + "\n"
);
console.log("[build] provenance:", JSON.stringify(provenance));
' "$PAYLOAD_DIR" "$DIGEST_FILE" "$VERSION" "$ARCH" "${PLATFORM:-linux-$ARCH}"

log "payload ready: $(du -sh "$PAYLOAD_DIR/server" | cut -f1) at $PAYLOAD_DIR/server"
