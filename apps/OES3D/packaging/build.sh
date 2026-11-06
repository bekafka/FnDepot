#!/usr/bin/env bash
# OES3D payload producer: copy the checked-in static page + Python LED service
# into the fnOS app payload. The app is intentionally arm64-only.
set -euo pipefail

ARCH="${ARCH:?ARCH is required (arm64)}"
VERSION="${VERSION:?VERSION is required}"
PAYLOAD_DIR="${PAYLOAD_DIR:?PAYLOAD_DIR is required}"
PLATFORM="${PLATFORM:-arm}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/payload"
APP_KEY="OES3D"

case "$ARCH" in
  arm64) ;;
  *) echo "OES3D only supports arm64 (got ARCH=$ARCH)" >&2; exit 2 ;;
esac
[ "$PLATFORM" = "arm" ] || { echo "OES3D only supports platform arm (got $PLATFORM)" >&2; exit 2; }
for f in www/index.html server/serve.py server/led_helper.py server/led-map.json; do
  [ -f "$SRC/$f" ] || { echo "missing payload file: $SRC/$f" >&2; exit 3; }
done

mkdir -p "$PAYLOAD_DIR" "$PAYLOAD_DIR/share"
cp -a "$SRC/." "$PAYLOAD_DIR/"
chmod 0755 "$PAYLOAD_DIR/server/serve.py" "$PAYLOAD_DIR/server/led_helper.py"

INDEX_SHA="$(sha256sum "$PAYLOAD_DIR/www/index.html" | awk '{print $1}')"
cat > "$PAYLOAD_DIR/share/PROVENANCE.json" <<JSON
{
  "app": "${APP_KEY}",
  "package_version": "${VERSION}",
  "project": "https://github.com/bekafka/FnDepot/tree/main/apps/${APP_KEY}",
  "source_author": "bekafka",
  "payload": {
    "kind": "checked-in-static-html-and-python-service",
    "index": "www/index.html",
    "index_sha256": "${INDEX_SHA}",
    "arch": "${ARCH}",
    "platform": "${PLATFORM}",
    "note": "fnOS OES-A311D arm64 only; service runs as root for sysfs LED access"
  }
}
JSON
printf 'OES3D payload ready: %s (index sha256 %s)\n' "$VERSION" "$INDEX_SHA"
