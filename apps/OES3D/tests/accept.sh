#!/bin/bash
# Minimal post-install smoke test for OES3D on an OES-A311D fnOS device.
set -euo pipefail
APP="${1:-OES3D}"
PORT="${PORT:-23080}"
base="http://127.0.0.1:${PORT}"
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
curl -fsS "$base/" | grep -q 'OES 3D'
curl -fsS "$base/api/leds" | grep -q '"ok": true'
echo "OES3D smoke OK: $APP :$PORT"
