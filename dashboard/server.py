#!/usr/bin/env python3
"""Serve the ai-fixme status page from live `fxa-sandbox-ctl snapshot` output.

A snapshot costs about 17 seconds, most of it waiting on Jira and GitHub. So a
background thread refreshes on an interval and every request is served from the
last result instantly. The page shows how old that result is, and never hides a
failed refresh behind stale data.
"""
import json
import re
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CTL = ROOT.parent / "fxa-sandbox-ctl"

class State:
    """Last good snapshot, plus what happened on the most recent attempt."""
    def __init__(self):
        self.lock = threading.Lock()
        self.data = None          # last SUCCESSFUL snapshot
        self.fetched_at = None    # when that succeeded
        self.error = None         # error from the most recent attempt, if any
        self.refreshing = False

    def read(self):
        with self.lock:
            age = None if self.fetched_at is None else round(time.time() - self.fetched_at)
            return {
                "snapshot": self.data,
                "age_seconds": age,
                "error": self.error,
                "refreshing": self.refreshing,
            }

STATE = State()

# `ctl tail` returns a screen hardcopy: ANSI sequences, NUL padding, and mangled
# box-drawing. Strip it to readable lines.
_ANSI = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07]*\x07|\x1b[()][A-Z0-9]")
_CTRL = re.compile(r"[\x00-\x08\x0b-\x1f\x7f]")

def clean_tail(raw, limit=60):
    out = []
    for line in _CTRL.sub("", _ANSI.sub("", raw)).splitlines():
        line = line.replace("\ufffd", "").rstrip()
        if line.strip():
            out.append(line)
    return out[-limit:]

TAIL = {}   # key -> (fetched_at, lines). The agent screen is the fast-moving
            # signal, so it gets its own endpoint rather than riding the 60s
            # snapshot, which spends most of its time waiting on Jira and GitHub.

def agent_tail(key):
    now = time.time()
    hit = TAIL.get(key)
    if hit and now - hit[0] < 4:
        return hit[1]
    branch = key.lower()
    try:
        proc = subprocess.run([str(CTL), "tail", branch],
                              capture_output=True, text=True, timeout=20,
                              errors="replace")
        lines = clean_tail(proc.stdout or "") if proc.returncode == 0 else \
                [f"(no output: {(proc.stderr or 'tail failed').strip()[:200]})"]
    except Exception as exc:
        lines = [f"(tail failed: {type(exc).__name__})"]
    TAIL[key] = (now, lines)
    return lines

def refresh(pipeline, already_claimed=False):
    """Returns False when a refresh was already in flight and this one did nothing."""
    if not already_claimed:
        with STATE.lock:
            if STATE.refreshing:
                return False
            STATE.refreshing = True
    try:
        proc = subprocess.run(
            [str(CTL), "--pipeline", pipeline, "snapshot"],
            capture_output=True, text=True, timeout=180,
        )
        if proc.returncode != 0:
            lines = (proc.stderr or "").strip().splitlines() or ["snapshot failed"]
            raise RuntimeError(lines[-1][:300])
        data = json.loads(proc.stdout)
        with STATE.lock:
            # Keep the previous snapshot on failure; only replace it on success.
            STATE.data, STATE.fetched_at, STATE.error = data, time.time(), None
    except Exception as exc:
        with STATE.lock:
            STATE.error = f"{type(exc).__name__}: {exc}"[:300]
    finally:
        with STATE.lock:
            STATE.refreshing = False
    return True

def loop(pipeline, interval):
    while True:
        refresh(pipeline)
        time.sleep(interval)

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # the page polls; access logs would bury any real error

    def _send(self, code, body, ctype):
        payload = body if isinstance(body, bytes) else body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/", "/index.html"):
            self._send(200, (ROOT / "index.html").read_bytes(), "text/html; charset=utf-8")
        elif path == "/api/snapshot":
            self._send(200, json.dumps(STATE.read()), "application/json")
        elif path == "/api/tail":
            from urllib.parse import parse_qs, urlparse
            key = (parse_qs(urlparse(self.path).query).get("key") or [""])[0]
            if not re.fullmatch(r"[A-Za-z][A-Za-z0-9]*-\d+", key):
                self._send(400, json.dumps({"error": "bad key"}), "application/json")
            else:
                self._send(200, json.dumps({"key": key, "lines": agent_tail(key)}),
                           "application/json")
        elif path == "/api/refresh":
            with STATE.lock:
                busy = STATE.refreshing
                if not busy:
                    STATE.refreshing = True   # claim it here, atomically
            if busy:
                self._send(200, json.dumps({"queued": False, "reason": "already refreshing"}),
                           "application/json")
            else:
                threading.Thread(target=refresh, args=(PIPELINE, True), daemon=True).start()
                self._send(202, json.dumps({"queued": True}), "application/json")
        else:
            self._send(404, json.dumps({"error": "not found"}), "application/json")

if __name__ == "__main__":
    PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8787
    PIPELINE = sys.argv[2] if len(sys.argv) > 2 else "fxa-ai-fixme"
    INTERVAL = int(sys.argv[3]) if len(sys.argv) > 3 else 60
    threading.Thread(target=loop, args=(PIPELINE, INTERVAL), daemon=True).start()
    print(f"ai-fixme dashboard: http://localhost:{PORT}  (pipeline {PIPELINE}, refresh {INTERVAL}s)")
    print("Ctrl-C to stop.")
    try:
        ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
    except KeyboardInterrupt:
        print("\nstopped.")
