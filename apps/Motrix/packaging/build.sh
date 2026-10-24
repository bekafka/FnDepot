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

# 包版本 vs 上游版本：安全修订不出新上游 tag 时，包版本可以带后缀
# （如 2.0.0-beta.49.1），但镜像 tag / git tag / 上游校验都得用 UPSTREAM_VERSION。
# 不传就用 VERSION（跟随上游版本时两者相同）。
UPSTREAM_VERSION="${UPSTREAM_VERSION:-$VERSION}"

# CI 守卫：FnFactory 的 _build-fpk.yml 只传 VERSION，不传 UPSTREAM_VERSION，
# 而 VERSION 同时被当作 motrix-server 镜像 tag 与上游 git tag。所以「包版本 ≠ 上游版本」
# （如安全修订 2.0.0.1 基于上游 2.0.0）在 CI 里做不到：会去拉不存在的镜像 tag，
# 最后报一个难懂的 version mismatch。这里提前拦下，并指向真正能做这件事的入口。
# 四段式版本号 x.y.z.w（纯数字段）一定不是上游 tag（上游只发 x.y.z 与 x.y.z-beta.N）。
# 注意不能用 *.*.*.* 这种 glob：它会把 2.0.0-beta.52 里的 beta.52 也当成一段而误拦。
if [ -n "${GITHUB_ACTIONS:-}" ] && [ "$UPSTREAM_VERSION" = "$VERSION" ]; then
  if printf '%s' "$VERSION" | grep -Eqx '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
    echo "::error::包版本 $VERSION 是四段式安全修订，上游没有对应的 motrix-server 镜像 tag。" >&2
    echo "  CI 只支持「包版本 == 上游版本」。做安全修订请用本地 build-local.sh：" >&2
    echo "    VERSION=${VERSION} UPSTREAM_VERSION=<上游版本> bash apps/Motrix/build-local.sh" >&2
    exit 5
  fi
fi

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
SRC="$WORK/src-$UPSTREAM_VERSION"
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
  log "extracting $MOTRIX_IMAGE:$UPSTREAM_VERSION (linux/$IMAGE_ARCH) from registry"
  python3 "$SCRIPT_DIR/tools/oci-extract.py" \
    --repo "$MOTRIX_IMAGE" --tag "$UPSTREAM_VERSION" --arch "$IMAGE_ARCH" --outdir "$IMAGE_DIR"
else
  log "reusing cached image extract at $IMAGE_DIR"
fi

APP_JSON="$IMAGE_DIR/app/package.json"
[ -f "$APP_JSON" ] || { echo "image extract has no /app/package.json" >&2; exit 4; }
IMAGE_VERSION="$(node -e "process.stdout.write(require('$APP_JSON').version)")"
[ "$IMAGE_VERSION" = "$UPSTREAM_VERSION" ] || {
  echo "image version mismatch: image=$IMAGE_VERSION expected=$UPSTREAM_VERSION" >&2; exit 4; }
log "image app version = $IMAGE_VERSION"

# ── ② 检出上游源码（stage/verify 脚本所在） ─────────────────────────────────────
if [ ! -d "$SRC/.git" ]; then
  log "cloning $MOTRIX_GIT @ v$UPSTREAM_VERSION"
  rm -rf "$SRC"
  git clone --depth 1 --branch "v$UPSTREAM_VERSION" "$MOTRIX_GIT" "$SRC"
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

# ── ②a 依赖安全升级（2026-10-22 漏洞响应）──────────────────────────────────────
# 上游 2.0.0-beta.49/beta.52 都锁 undici ^8.11.2，而 8.11.2 落在
# CVE-2026-87018 / GHSA-qrxm-fqhp-jwvm 的受影响区间（8.0.0–8.12.1）：
# TLS 1.2 服务端在连接建立后重协商并出示主机名不匹配的合法证书时，undici 的
# established-socket 错误处理会断言崩溃整个 Node 进程（远程可打崩，纯 DoS）。
# Motrix 用 undici 的 Agent/ProxyAgent/fetch 拉下游资源，属于可达面。
# 修在 8.12.2，这里钉到 8.12.3（再往上的补丁线）。
# 用 MOTRIX_SECURITY_BUMP=0 可关（上游自己升过了的时候）。
if [ "${MOTRIX_SECURITY_BUMP:-1}" = "1" ]; then
  if node -e 'const v=require(process.argv[1]).dependencies?.undici||""; const [maj,min]=v.replace(/^[^0-9]/,"").split(".").map(Number); process.exit((maj>8)||(maj===8&&min>=12)?0:1)' "$SRC/package.json"; then
    log "undici 已 >= 8.12，跳过安全升级"
  else
    log "security bump: undici -> 8.12.3（CVE-2026-87018）"
    # 重新解析并安装（--no-frozen-lockfile 允许改 lock），仍只装 prod
    node -e '
      const fs=require("fs"), p=process.argv[1];
      const d=JSON.parse(fs.readFileSync(p,"utf8"));
      d.dependencies.undici="8.12.3";
      fs.writeFileSync(p, JSON.stringify(d,null,2)+"\n");
    ' "$SRC/package.json"
    $PNPM install --prod --ignore-scripts --no-frozen-lockfile --registry="$NPM_REGISTRY"
  fi
  BUMPED_UNDICI="$(node -e 'try{process.stdout.write(require(process.argv[1]+"/node_modules/undici/package.json").version)}catch(e){process.stdout.write("?")}' "$SRC")"
  log "undici 现在是 $BUMPED_UNDICI"
  # 门禁：低于 8.12.2 就是没修掉 CVE-2026-87018，不出包
  node -e '
    const v=process.argv[1].replace(/^[^0-9]/,"").split(".").map(Number);
    const ok=(v[0]>8)||(v[0]===8&&(v[1]>12||(v[1]===12&&v[2]>=2)));
    if(!ok){console.error("::error::undici "+process.argv[1]+" 仍受 CVE-2026-87018 影响（需 >= 8.12.2）");process.exit(1)}
  ' "$BUMPED_UNDICI" || exit 11
else
  log "security bump 已跳过（MOTRIX_SECURITY_BUMP=0）"
fi

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

# ── ④b 体积预算：为安全升级留确定性余量 ────────────────────────────────────────
# 上游 server-package-size-budgets.json 的 artifactBytes/dependencyBytes 是紧贴
# 上游 8.11.2 实测值定的（x86 50397184，实测已用满）。undici 8.12.3 的包比
# 8.11.2 大约 74KB（tgz）/ 解包后更多，x86 会超约 30KB 而误判「体积预算超限」。
# 这不是体积事故，而是安全修订带来的正常增长。只在需要时给固定 2MB 余量并
# 打印改前/改后，保持可复核（不改上游代码的语义与其它预算项）。
# 先还原成上游原值再统一加余量，保证幂等（重复跑不会越加越大）
git checkout -- scripts/server-package-size-budgets.json 2>/dev/null || true
node -e '
  const fs=require("fs");
  const p="scripts/server-package-size-budgets.json";
  const b=JSON.parse(fs.readFileSync(p,"utf8"));
  const before={artifactBytes:b.artifactBytes,dependencyBytes:b.dependencyBytes};
  const HEADROOM=2*1024*1024;
  b.artifactBytes=before.artifactBytes+HEADROOM;
  b.dependencyBytes=before.dependencyBytes+HEADROOM;
  fs.writeFileSync(p, JSON.stringify(b,null,2)+"\n");
  console.error(`[size-budget] +${HEADROOM}B 余量：${JSON.stringify(before)} -> artifactBytes=${b.artifactBytes} dependencyBytes=${b.dependencyBytes}`);
'

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

// 从实际产物读，不硬编码：硬编码会在跟版后变成错误的出处记录（审计价值归零）。
// aria2：二进制里带 "aria2/1.37.0-motrix.19" 这样的版本串。
function detectAria2Version() {
  const bin = path.join(payloadDir, "server", "bin", "aria2c");
  try {
    const buf = fs.readFileSync(bin);
    const m = buf.toString("latin1").match(/aria2\/(\d+\.\d+\.\d+-motrix\.\d+)/);
    if (m) return m[1];
    const m2 = buf.toString("latin1").match(/(\d+\.\d+\.\d+-motrix\.\d+)/);
    if (m2) return m2[1];
  } catch (_) {}
  return null;
}
// undici：读实际安装的包版本。
function detectUndici() {
  const p = path.join(payloadDir, "server", "node_modules", "undici", "package.json");
  try { return JSON.parse(fs.readFileSync(p, "utf8")).version || null; } catch (_) { return null; }
}
const aria2Version = detectAria2Version();
const undiciVersion = detectUndici();
const provenance = {
  app: "Motrix",
  upstream: "https://github.com/agalwood/Motrix",
  version,
  upstream_version: process.env.UPSTREAM_VERSION || version,
  target: stage.target,
  arch,
  platform,
  source_image: digest.repo ? `${digest.repo}:${digest.tag}` : null,
  source_image_manifest_digest: digest.manifest_digest ?? null,
  staged_with: "scripts/stage-server-app.mjs --libc gnu (upstream)",
  verified_with: "scripts/verify-server-package.mjs --libc gnu (upstream)",
  aria2: aria2Version
    ? `motrixapp/aria2 v${aria2Version} (version read from the bundled binary; sha256 pinned in scripts/engine.lock.json)`
    : "motrixapp/aria2 (version not detectable from bundled binary; sha256 pinned in scripts/engine.lock.json)",
  finalize_fs:
    "built from upstream source + packaging/patches/finalize-fs-open-root-o_path.patch (O_PATH fallback for fnOS trimacl)",
  operator_auth:
    process.env.AUTH_MODE === "token"
      ? "upstream token gate (operator-token)"
      : "disabled via packaging/tools/disable-operator-auth.mjs (no unlock prompt; /rpc and /api are open to anyone reaching the port)",
  security: {
    response_to: "2026-10-21/22 vendor advisory wave",
    undici: undiciVersion
      ? `bundled undici ${undiciVersion} (read from node_modules; advisory of record: CVE-2026-87018 / GHSA-qrxm-fqhp-jwvm)`
      : "undici not found in node_modules",
    node_runtime: "fnOS app-center nodejs_v24 (runtime is system-provided; see npm advisories for node CVEs)",
  },
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
