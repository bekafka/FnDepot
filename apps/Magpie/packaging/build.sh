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
command -v go >/dev/null 2>&1 || { echo "需要 go（>= 1.26.3；GOTOOLCHAIN 会自动取固定版本）" >&2; exit 3; }

# ── 工具链固定 ────────────────────────────────────────────────────────────────
# 标准库漏洞只能靠「用修好的 Go 重编」解决（源码依赖升级管不到 stdlib）。
# go1.27.3 / go1.26.10 起修掉 crypto/x509 的中间证书黑名单（GO-2026-6809 /
# CVE-2026-111943）；比它旧的工具链编出来的二进制一律带这个洞。
# 因此这里不再用 GOTOOLCHAIN=auto 跟随 go.mod 的 go 1.26.8，而是钉死到已修复版本。
GO_TOOLCHAIN="${GO_TOOLCHAIN:-go1.27.3}"
export GOTOOLCHAIN="$GO_TOOLCHAIN"
GO_VERSION_RAW="$(go version)"
log "toolchain: $GO_VERSION_RAW (pinned GOTOOLCHAIN=$GO_TOOLCHAIN, host $(uname -m))"
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

# ── 1.5 漏洞门禁自愈（govulncheck 驱动，不再硬编码依赖 pin）─────────────────────
# 历史包袱：这一节以前是硬编码的「依赖安全升级」（x/net → v0.60.0、x/image → v0.46.0 …），
# 每来一波新的 Go advisory（GO-2026-xxxx）这行 pin 就会过期一次，于是自动跟版连续多轮卡在
# 同一个门禁上（2026-10-22 / 10-27 / 11-01 各一次，最后一次是 GO-2026-6860）。根因不是上游
# 引入新洞，而是「本地清单没有巡检」——pin 是死的，公告是活的。
#
# 现在改成「门禁驱动自愈」，让这条链路自己跟得上公告，不需要人工改版本号：
#   · 只升 govulncheck 明确报出「Found in → Fixed in」的模块，且只升到 Fixed in（不盲目追
#     latest，避免无谓漂移）；若 Fixed in 的 go.mod 强制兄弟包升级（如 x/net 强抬 x/text），
#     交给 go get 一并解析，不在脚本里再写死；
#   · 升完重新扫描，最多 3 轮，覆盖多模块 / 链式公告；
#   · 只有「拿不到 Fixed in」或「3 轮后仍可达」才失败，并在日志里列出待人工处理的 advisory；
#   · 标准库漏洞 go get 修不了：明确报错并提示抬 GO_TOOLCHAIN（不静默放过）。
# 临时排障仍用 MAGPIE_SKIP_VULNCHECK=1 跳过整个门禁。
VULNLOG="${VULNLOG:-/tmp/magpie-govulncheck.log}"
MAX_FIX_ROUNDS="${MAX_FIX_ROUNDS:-3}"
GATE_STATUS="skipped"

run_govulncheck() {
  local rc=0
  (
    cd "$SRC"
    set -o pipefail
    # 必须用与真实构建一致的上下文（-tags nogui + CGO_ENABLED=0）：否则 ./... 会把
    # GTK/Wails 的 cgo 包一起 type-check，在无 gtk4/webkitgtk 的 runner 上误报失败。
    CGO_ENABLED=0 go run golang.org/x/vuln/cmd/govulncheck@v1.9.0 -tags nogui ./... 2>&1 \
      | tee "$VULNLOG" | tail -40
  ) || rc=$?
  return "$rc"
}

# A > B 时返回 0（这里只用于 x/*、compress 这类无 prerelease 的纯数字版本）
ver_gt() {
  [ "$1" = "$2" ] && return 1
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

# 已知安全的依赖「下限」——注意是 lower bound，不是 pin：
#   · 上游已锁更高版本 → 不动；
#   · 新的 advisory 要求更高 → 下面的 govulncheck 自愈会继续往上抬；
#   所以这一行过期也不会让构建失败，只是少一点主动性。可用 MAGPIE_SECURITY_FLOOR=0 关掉。
SECURITY_FLOOR="${MAGPIE_SECURITY_FLOOR_ARGS:-golang.org/x/net@v0.62.0 golang.org/x/text@v0.43.0 golang.org/x/image@v0.46.0 github.com/klauspost/compress@v1.18.7}"

if [ "${MAGPIE_SKIP_VULNCHECK:-0}" != "1" ] && [ -z "${SKIP_VULNCHECK:-}" ] && [ "${MAGPIE_SECURITY_FLOOR:-1}" = "1" ]; then
  FLOOR_ARGS=""
  for spec in $SECURITY_FLOOR; do
    m="${spec%@*}"; v="${spec##*@}"
    cur="$( cd "$SRC" && go list -m -f '{{.Version}}' "$m" 2>/dev/null || true )"
    if [ -z "$cur" ] || ver_gt "$v" "$cur"; then FLOOR_ARGS="$FLOOR_ARGS $spec"; fi
  done
  if [ -n "$FLOOR_ARGS" ]; then
    log "依赖安全下限（只升不降）：${FLOOR_ARGS}"
    FLOOR_OK=0
    for i in 1 2 3; do
      # shellcheck disable=SC2086
      if ( cd "$SRC" && GOFLAGS=-mod=mod go get $FLOOR_ARGS ); then FLOOR_OK=1; break; fi
      log "依赖安全下限 go get 失败，第 ${i} 次重试（${i}0s 后）"; sleep $((i * 10))
    done
    # 下限失败不硬停：交给下面 govulncheck 的按 Fixed-in 自愈兜底
    [ "$FLOOR_OK" -eq 1 ] || echo "::warning::依赖安全下限升级失败，继续交给 govulncheck 自愈"
  fi
fi

if [ "${MAGPIE_SKIP_VULNCHECK:-0}" != "1" ] && [ -z "${SKIP_VULNCHECK:-}" ]; then
  ROUND=0
  while :; do
    ROUND=$((ROUND + 1))
    log "govulncheck（第 ${ROUND} 轮，符号级可达门禁）"
    GVC_RC=0
    run_govulncheck || GVC_RC=$?

    # 运行本身失败（多为网络抖动，如拉 vuln DB / 模块超时）→ 重试 2 次再判死
    if [ "$GVC_RC" -ne 0 ] && ! grep -qE 'Your code is affected by [0-9]+ vulnerabilit' "$VULNLOG"; then
      for i in 1 2; do
        log "govulncheck 运行失败（rc=$GVC_RC，第 ${i} 次重试，${i}0s 后）"
        sleep $((i * 10))
        GVC_RC=0
        run_govulncheck || GVC_RC=$?
        grep -qE 'Your code is affected by [0-9]+ vulnerabilit' "$VULNLOG" && break
        [ "$GVC_RC" -eq 0 ] && break
      done
    fi

    # 运行本身失败（不是「发现漏洞」）→ 直接中止
    if [ "$GVC_RC" -ne 0 ] && ! grep -qE 'Your code is affected by [0-9]+ vulnerabilit' "$VULNLOG"; then
      echo "::error::govulncheck 运行失败（rc=$GVC_RC），见上；修好或用 MAGPIE_SKIP_VULNCHECK=1 临时跳过"
      exit 9
    fi

    # 没有可达漏洞 → 门禁通过
    if ! grep -qE 'Your code is affected by [1-9][0-9]* vulnerabilit' "$VULNLOG"; then
      log "govulncheck 通过：没有被调用到的已知漏洞"
      GATE_STATUS="passed"
      break
    fi

    # 有可达漏洞：把 Found in / Fixed in 逐对解析出来
    PAIRS="$(awk '
      /Found in: / { split($0, a, ": "); found=a[2] }
      /Fixed in: / { split($0, b, ": "); fixed=b[2]; if (found != "" && fixed != "") print found "\t" fixed; found=""; fixed="" }
    ' "$VULNLOG")"

    if [ -z "$PAIRS" ]; then
      echo "::error::govulncheck 报可达漏洞但没有 Fixed in，无法自愈；需人工处理（见上）"
      grep -E 'Vulnerability #|Found in:|Fixed in:' "$VULNLOG" || true
      exit 9
    fi

    # 汇总每个模块要升到的最高 Fixed in；标准库单列；无 Fixed in 的单列
    declare -A WANT=()
    STDLIB_FIX=""
    UNFIXED=""
    while IFS=$'\t' read -r found fixed; do
      [ -z "$found" ] && continue
      case "$found" in
        stdlib@*|go@*|go[0-9]*) STDLIB_FIX="$fixed"; continue ;;
      esac
      case "$fixed" in
        ""|N/A|none|unknown) UNFIXED="$UNFIXED $found"; continue ;;
      esac
      mod="${fixed%@*}"; want="${fixed##*@}"
      cur="$( cd "$SRC" && go list -m -f '{{.Version}}' "$mod" 2>/dev/null || true )"
      if [ -n "$cur" ] && ! ver_gt "$want" "$cur"; then
        log "  $mod 现有 ${cur} 已不低于 Fixed in ${want}，跳过"
        continue
      fi
      if [ -z "${WANT[$mod]:-}" ] || ver_gt "$want" "${WANT[$mod]}"; then
        WANT[$mod]="$want"
      fi
    done <<< "$PAIRS"

    if [ -n "$STDLIB_FIX" ]; then
      echo "::error::govulncheck 报标准库漏洞，go get 无法修复；请把 GO_TOOLCHAIN 抬到 ${STDLIB_FIX} 或更高（当前 ${GOTOOLCHAIN}）"
      exit 9
    fi
    if [ -n "$UNFIXED" ]; then
      echo "::error::以下模块的 advisory 没有 Fixed in，无法自愈：${UNFIXED}"
      exit 9
    fi
    if [ "${#WANT[@]}" -eq 0 ]; then
      echo "::error::govulncheck 仍报可达漏洞，但没有可升级到的 Fixed in 版本（见上）"
      exit 9
    fi
    if [ "$ROUND" -gt "$MAX_FIX_ROUNDS" ]; then
      echo "::error::已自动升级 ${MAX_FIX_ROUNDS} 轮仍存在可达漏洞，需人工介入"
      grep -E 'Vulnerability #|Found in:|Fixed in:' "$VULNLOG" || true
      exit 9
    fi

    UPGRADES=""
    for mod in "${!WANT[@]}"; do UPGRADES="$UPGRADES $mod@${WANT[$mod]}"; done
    log "自动按 Fixed in 升级：${UPGRADES}"
    GET_OK=0
    for i in 1 2 3; do
      # shellcheck disable=SC2086
      if ( cd "$SRC" && GOFLAGS=-mod=mod go get $UPGRADES ); then GET_OK=1; break; fi
      log "go get 失败，第 ${i} 次重试（${i}0s 后）"; sleep $((i * 10))
    done
    [ "$GET_OK" -eq 1 ] || { echo "::error::依赖升级 go get 连续失败（网络或版本不可用）：${UPGRADES}"; exit 9; }
    log "go.mod 现在锁定的关键版本："
    grep -E 'golang.org/x/(image|net|text|sys) |github.com/klauspost/compress ' "$SRC/go.mod" | sed 's/^/  /' || true
  done
else
  log "govulncheck 已跳过（MAGPIE_SKIP_VULNCHECK=1）"
fi

# ── 2. 构建 ──────────────────────────────────────────────────────────────────
mkdir -p "$PAYLOAD_DIR/bin"
log "go build (-tags nogui, CGO_ENABLED=0, GOTOOLCHAIN=$GOTOOLCHAIN)"
(
  cd "$SRC"
  CGO_ENABLED=0 GOOS=linux GOARCH="$ARCH" GOTOOLCHAIN="$GOTOOLCHAIN" \
    go build -tags nogui -trimpath \
    -ldflags "-s -w -X main.version=$TAG" \
    -o "$BIN" .
)
[ -x "$BIN" ] || { echo "构建产物不存在：$BIN" >&2; exit 5; }

# 工具链自证：产物必须是用钉死的已修复 Go 编的，否则标准库漏洞还在
BUILT_GO="$(go version -m "$BIN" 2>/dev/null | sed -n 's/^[^:]*: //p' | head -n 1)"
log "binary built with: ${BUILT_GO:-未知}"
case "$BUILT_GO" in
  go1.27.3*|go1.27.[4-9]*|go1.2[89].*|go1.[3-9][0-9].*) ;;
  *) echo "构建所用 Go 版本不在已修复范围（$BUILT_GO），拒绝出包" >&2; exit 10 ;;
esac

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
  grep -qF "?k=$WEB_KEY" "$UI_CONFIG" || { echo "入口 URL 注入失败：$UI_CONFIG" >&2; exit 8; }
  echo "  入口 URL 已写入面板密钥（$UI_CONFIG）"
else
  echo "警告：找不到 $UI_CONFIG（没有先组装包模板？），入口里的 __WEB_KEY__ 未被替换" >&2
fi

# ── 4. PROVENANCE ────────────────────────────────────────────────────────────
SHA="$(sha256sum "$BIN" | awk '{print $1}')"
SIZE="$(stat -c%s "$BIN")"
mod_version() { ( cd "$SRC" && go list -m -f '{{.Version}}' "$1" 2>/dev/null || echo unknown ); }
XN="$(mod_version golang.org/x/net)"; XT="$(mod_version golang.org/x/text)"
XI="$(mod_version golang.org/x/image)"; KC="$(mod_version github.com/klauspost/compress)"
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
    "go_toolchain_pinned": "$GOTOOLCHAIN",
    "built_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
    "builder": "$(hostname 2>/dev/null || echo unknown)"
  },
  "security": {
    "response_to": "由 govulncheck 符号级可达门禁驱动，按 advisory 的 Fixed in 自动升级需要修的模块（2026-11-01 起自愈，不再硬编码依赖 pin）",
    "go_stdlib_fix": "GOTOOLCHAIN=$GOTOOLCHAIN（crypto/x509 中间证书黑名单 GO-2026-6809/CVE-2026-111943 等）",
    "modules": {
      "golang.org/x/net": "$XN",
      "golang.org/x/text": "$XT",
      "golang.org/x/image": "$XI",
      "github.com/klauspost/compress": "$KC"
    },
    "govulncheck": "符号级可达门禁：$GATE_STATUS（升级过程见 CI 日志）"
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
