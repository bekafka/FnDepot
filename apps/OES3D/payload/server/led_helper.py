#!/usr/bin/env python3
"""Privileged LED helper for the oes-3d page on fnOS.

Runs as root (systemd) and exposes a tiny newline-delimited JSON protocol over
/run/oes-led/oes-led.sock. The web server runs as the normal NAS user and calls
this helper to read/write the five green LED sysfs entries.
"""
import grp
import json
import os
import socketserver
from pathlib import Path

LED_ROOT = Path("/sys/class/leds")
SOCKET_PATH = os.environ.get("OES_LED_SOCKET", "/run/oes-led/oes-led.sock")
DEFAULT_LEDS = [
    {"name": "green:disk_2", "label": "硬盘 2（已插）", "probe": "ata3"},
    {"name": "green:disk_1", "label": "空插槽", "probe": "ata2"},
    {"name": "green:disk", "label": "硬盘 1（已插）", "probe": "ata1"},
    {"name": "green:lan", "label": "网络", "probe": "net:end0"},
    {"name": "green:power", "label": "电源", "probe": "always:on"},
]
ALLOWED_NAMES = {item["name"] for item in DEFAULT_LEDS}


def load_leds():
    """Read led-map.json when present; fall back to the built-in order."""
    config = Path(__file__).with_name("led-map.json")
    try:
        data = json.loads(config.read_text(encoding="utf-8"))
        items = data.get("leds") if isinstance(data, dict) else data
        if isinstance(items, list) and len(items) == 5:
            parsed = []
            for index, item in enumerate(items):
                name = str(item.get("name", "")).strip()
                if name not in ALLOWED_NAMES:
                    raise ValueError("unsupported LED name: %s" % name)
                parsed.append({"name": name, "label": str(item.get("label") or name), "probe": str(item.get("probe") or "")})
            return parsed
    except FileNotFoundError:
        pass
    except Exception as exc:
        print("led-helper: ledger map ignored: %s" % exc, flush=True)
    return [dict(item) for item in DEFAULT_LEDS]


def current_trigger(base):
    try:
        text = (base / "trigger").read_text(encoding="utf-8").strip()
    except OSError:
        return "unknown"
    for token in text.split():
        if token.startswith("[") and token.endswith("]"):
            return token[1:-1]
    return "none"


def read_one(index, item):
    base = LED_ROOT / item["name"]
    result = {"index": index, "name": item["name"], "label": item["label"], "probe": item.get("probe", ""), "on": False}
    try:
        brightness = int((base / "brightness").read_text(encoding="utf-8").strip())
        max_brightness = int((base / "max_brightness").read_text(encoding="utf-8").strip() or "1")
        result.update({"brightness": brightness, "max_brightness": max_brightness, "trigger": current_trigger(base), "on": brightness > 0})
    except (OSError, ValueError) as exc:
        result["error"] = str(exc)
    return result


def write_one(item, on):
    base = LED_ROOT / item["name"]
    # LED core: a non-zero brightness is ignored while a trigger owns the LED,
    # so clear the trigger first for both on and off.
    (base / "trigger").write_text("none\n", encoding="utf-8")
    (base / "brightness").write_text("1\n" if on else "0\n", encoding="utf-8")


def probe_state(item):
    """Return the hardware-presence state for a mapped LED, or None if not probed."""
    probe = str(item.get("probe", "")).strip()
    if probe.startswith("ata"):
        port = Path("/sys/class/ata_port") / probe / "device"
        try:
            return any(port.glob("host*/target*"))
        except OSError:
            return False
    if probe.startswith("net:"):
        try:
            return (Path("/sys/class/net") / probe[4:] / "carrier").read_text(encoding="utf-8").strip() == "1"
        except OSError:
            return False
    if probe == "always:on":
        return True
    if probe == "always:off":
        return False
    return None


def reconcile():
    """After a full-on request, correct LEDs to match actual hardware presence."""
    leds = load_leds()
    corrections = []
    for item in leds:
        target = probe_state(item)
        if target is not None:
            write_one(item, bool(target))
            corrections.append({"name": item["name"], "on": bool(target)})
    result = status()
    result["reconciled"] = corrections
    return result


def status():
    leds = load_leds()
    return {"ok": True, "leds": [read_one(i, item) for i, item in enumerate(leds)]}


def apply_leds(values):
    leds = load_leds()
    if len(values) != len(leds):
        return {"ok": False, "error": "expected %d states" % len(leds)}
    for item, value in zip(leds, values):
        write_one(item, bool(value))
    return status()


def handle(request):
    cmd = str(request.get("cmd", "status"))
    if cmd == "status":
        return status()
    if cmd == "set":
        leds = load_leds()
        index = int(request.get("index", -1))
        if index < 0 or index >= len(leds):
            return {"ok": False, "error": "invalid LED index"}
        write_one(leds[index], bool(request.get("on")))
        return status()
    if cmd == "all":
        return apply_leds([bool(request.get("on"))] * len(load_leds()))
    if cmd == "states":
        return apply_leds([bool(value) for value in request.get("states", [])])
    if cmd == "reconcile":
        return reconcile()
    return {"ok": False, "error": "unknown command: %s" % cmd}


class RequestHandler(socketserver.StreamRequestHandler):
    def handle(self):
        line = self.rfile.readline(65536)
        if not line:
            return
        try:
            request = json.loads(line.decode("utf-8"))
            response = handle(request)
        except Exception as exc:
            response = {"ok": False, "error": str(exc)}
        self.wfile.write((json.dumps(response, ensure_ascii=False) + "\n").encode("utf-8"))


class ThreadedUnixServer(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    socket_path = Path(SOCKET_PATH)
    socket_path.parent.mkdir(parents=True, exist_ok=True)
    if socket_path.exists():
        socket_path.unlink()
    server = ThreadedUnixServer(str(socket_path), RequestHandler)
    os.chmod(socket_path, 0o660)
    try:
        gid = grp.getgrnam("Users").gr_gid
        os.chown(socket_path, 0, gid)
    except KeyError:
        pass
    print("led-helper listening on %s" % socket_path, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
