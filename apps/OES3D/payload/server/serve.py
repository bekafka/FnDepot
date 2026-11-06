#!/usr/bin/env python3
"""Static file + LED API server for the oes-3d preview on fnOS (LAN only)."""
import json
import os
import re
import socket
import threading
import time
from datetime import datetime, timedelta
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
# In the FPK layout serve.py lives in app/server and the page in app/www.
_DEFAULT_STATIC = os.path.join(BASE_DIR, "..", "www")
STATIC_ROOT = os.environ.get("OES_STATIC_ROOT") or (_DEFAULT_STATIC if os.path.isfile(os.path.join(_DEFAULT_STATIC, "index.html")) else BASE_DIR)
os.chdir(STATIC_ROOT)

LED_SOCKET = os.environ.get("OES_LED_SOCKET", "/run/oes-led/oes-led.sock")
try:
    import led_helper
except Exception as exc:  # keep static serving usable even if the helper is missing
    led_helper = None
    LED_HELPER_IMPORT_ERROR = exc


_reconcile_timer = None
_reconcile_lock = threading.Lock()


def cancel_reconcile():
    global _reconcile_timer
    with _reconcile_lock:
        if _reconcile_timer is not None:
            _reconcile_timer.cancel()
            _reconcile_timer = None


def schedule_reconcile(delay=5.0):
    """After an all-on request, re-check hardware presence 5 seconds later."""
    global _reconcile_timer

    def run():
        global _reconcile_timer
        with _reconcile_lock:
            _reconcile_timer = None
        try:
            led_call({"cmd": "reconcile"})
        except Exception as exc:
            print("oes-3d: reconcile failed: %s" % exc, flush=True)

    with _reconcile_lock:
        if _reconcile_timer is not None:
            _reconcile_timer.cancel()
        _reconcile_timer = threading.Timer(delay, run)
        _reconcile_timer.daemon = True
        _reconcile_timer.start()


def led_call(payload):
    """When the web service runs as root, write sysfs directly; otherwise use the helper."""
    if os.geteuid() == 0 and led_helper is not None:
        return led_helper.handle(payload)
    return led_rpc(payload)


def led_rpc(payload, timeout=2.0):
    """Send one newline-delimited JSON command to the privileged LED helper."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(timeout)
        sock.connect(LED_SOCKET)
        sock.sendall((json.dumps(payload, ensure_ascii=False) + "\n").encode("utf-8"))
        chunks = []
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
            if chunk.endswith(b"\n"):
                break
        raw = b"".join(chunks).decode("utf-8", "replace").strip()
    if not raw:
        raise RuntimeError("empty LED helper response")
    return json.loads(raw)


SCHEDULE_FILE = os.environ.get("OES_SCHEDULE_FILE") or os.path.join(os.environ.get("TRIM_PKGVAR") or "/vol1/app/oes-3d-data", "led-schedule.json")
DEFAULT_SCHEDULE = {"enabled": True, "on_time": "07:00", "off_time": "23:00"}
_schedule = dict(DEFAULT_SCHEDULE)
_schedule_lock = threading.Lock()
_last_schedule_run = {"on": None, "off": None}
TIME_RE = re.compile(r"^([01]\d|2[0-3]):[0-5]\d$")


def load_schedule():
    try:
        data = json.loads(open(SCHEDULE_FILE, encoding="utf-8").read())
        if isinstance(data, dict) and TIME_RE.match(str(data.get("on_time", ""))) and TIME_RE.match(str(data.get("off_time", ""))):
            return {"enabled": bool(data.get("enabled", True)), "on_time": str(data["on_time"]), "off_time": str(data["off_time"])}
    except FileNotFoundError:
        pass
    except Exception as exc:
        print("oes-3d: schedule file ignored: %s" % exc, flush=True)
    return dict(DEFAULT_SCHEDULE)


def schedule_payload():
    with _schedule_lock:
        data = dict(_schedule)
    payload = {"ok": True, **data}
    if data["enabled"]:
        payload["next_on"] = next_occurrence(data["on_time"])
        payload["next_off"] = next_occurrence(data["off_time"])
    else:
        payload["next_on"] = None
        payload["next_off"] = None
    return payload


def next_occurrence(hhmm):
    now = datetime.now()
    hour, minute = [int(part) for part in hhmm.split(":")]
    target = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
    if target <= now:
        target += timedelta(days=1)
    return target.strftime("%Y-%m-%d %H:%M")


def update_schedule(data):
    enabled = bool(data.get("enabled", True))
    on_time = str(data.get("on_time", "")).strip()
    off_time = str(data.get("off_time", "")).strip()
    if not TIME_RE.match(on_time) or not TIME_RE.match(off_time):
        raise ValueError("时间必须是 HH:MM（00:00–23:59）")
    if on_time == off_time:
        raise ValueError("自动开和自动关时间不能相同")
    with _schedule_lock:
        _schedule.update({"enabled": enabled, "on_time": on_time, "off_time": off_time})
        data_to_write = dict(_schedule)
    _last_schedule_run["on"] = None
    _last_schedule_run["off"] = None
    os.makedirs(os.path.dirname(SCHEDULE_FILE), exist_ok=True)
    try:
        os.chmod(os.path.dirname(SCHEDULE_FILE), 0o755)
    except OSError:
        pass
    tmp = SCHEDULE_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fp:
        json.dump(data_to_write, fp, ensure_ascii=False, indent=2)
        fp.write("\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, SCHEDULE_FILE)
    return schedule_payload()


def scheduler_loop():
    """Daily all-off/all-on timer; all-on reuses the 5 s hardware reconcile."""
    while True:
        try:
            now = datetime.now()
            today = now.date().isoformat()
            current = now.strftime("%H:%M")
            with _schedule_lock:
                config = dict(_schedule)
            if config["enabled"]:
                if current == config["off_time"] and _last_schedule_run["off"] != today:
                    _last_schedule_run["off"] = today
                    cancel_reconcile()
                    led_call({"cmd": "all", "on": False})
                    print("oes-3d: scheduled all-off %s" % current, flush=True)
                if current == config["on_time"] and _last_schedule_run["on"] != today:
                    _last_schedule_run["on"] = today
                    result = led_call({"cmd": "all", "on": True})
                    if result.get("ok"):
                        schedule_reconcile(5.0)
                    print("oes-3d: scheduled all-on %s" % current, flush=True)
        except Exception as exc:
            print("oes-3d: scheduler error: %s" % exc, flush=True)
        time.sleep(5)


_schedule.update(load_schedule())


class Handler(SimpleHTTPRequestHandler):
    # Development preview: always revalidate so a redeployed HTML shows up immediately.
    def end_headers(self):
        self.send_header("Cache-Control", "no-store, max-age=0")
        super().end_headers()

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)

    def send_json(self, code, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urlsplit(self.path).path
        if path == "/api/leds/schedule":
            self.send_json(200, schedule_payload())
            return
        if path == "/api/leds":
            try:
                self.send_json(200, led_call({"cmd": "status"}))
            except Exception as exc:
                self.send_json(503, {"ok": False, "error": "LED helper unavailable: %s" % exc})
            return
        super().do_GET()

    def do_POST(self):
        path = urlsplit(self.path).path
        if path == "/api/leds/schedule":
            try:
                length = int(self.headers.get("Content-Length", "0") or "0")
                if length <= 0 or length > 4096:
                    raise ValueError("invalid request body")
                data = json.loads(self.rfile.read(length).decode("utf-8"))
                if not isinstance(data, dict):
                    raise ValueError("request must be a JSON object")
                self.send_json(200, update_schedule(data))
            except Exception as exc:
                self.send_json(400, {"ok": False, "error": str(exc)})
            return
        if path != "/api/leds":
            self.send_json(404, {"ok": False, "error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0") or "0")
            if length <= 0 or length > 4096:
                raise ValueError("invalid request body")
            data = json.loads(self.rfile.read(length).decode("utf-8"))
            if not isinstance(data, dict):
                raise ValueError("request must be a JSON object")
            if data.get("states") is not None:
                states = data["states"]
                if not isinstance(states, list) or len(states) != 5:
                    raise ValueError("states must be a list of 5 booleans")
                request = {"cmd": "states", "states": [bool(x) for x in states]}
            elif data.get("all") is True:
                request = {"cmd": "all", "on": bool(data.get("on"))}
            else:
                request = {"cmd": "set", "index": int(data["index"]), "on": bool(data.get("on"))}
            if request.get("cmd") != "all" or not request.get("on"):
                cancel_reconcile()
            result = led_call(request)
            if request.get("cmd") == "all" and request.get("on") and result.get("ok"):
                schedule_reconcile(5.0)
            self.send_json(200 if result.get("ok") else 400, result)
        except Exception as exc:
            self.send_json(400, {"ok": False, "error": str(exc)})


if __name__ == "__main__":
    threading.Thread(target=scheduler_loop, daemon=True).start()
    port = int(os.environ.get("PORT", "23080"))
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
