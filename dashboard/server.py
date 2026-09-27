#!/usr/bin/env python3
"""Serve the ai-fixme status page from two live feeds.

Two feeds, two cadences. `snapshot --agents` is what the runners are doing:
local files, one rsync and one ssh per runner, tens of seconds. `snapshot` is
the ticket state: Jira and GitHub, a minute or more. Each refreshes on its own
timer in the background, every request is served from the last result at once,
and the page shows how old each result is. A failed refresh keeps the previous
result rather than blanking the page.
"""
import json
import os
import re
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CTL = ROOT.parent / "fxa-sandbox-ctl"
SESSION_DIR = Path(os.environ.get("FXA_SESSION_DIR") or Path.home() / ".claude/state/agent-sessions")


class Feed:
    """Last good result of one command, plus what happened on the latest attempt."""
    def __init__(self, name, args, interval, timeout):
        self.name, self.args, self.interval, self.timeout = name, args, interval, timeout
        self.lock = threading.Lock()
        self.data = None          # last SUCCESSFUL result
        self.fetched_at = None    # when that succeeded
        self.error = None         # error from the most recent attempt, if any
        self.refreshing = False

    def read(self):
        with self.lock:
            age = None if self.fetched_at is None else round(time.time() - self.fetched_at)
            return self.data, age, self.error, self.refreshing

    def refresh(self, already_claimed=False):
        """Returns False when a refresh was already in flight and this one did nothing."""
        if not already_claimed:
            with self.lock:
                if self.refreshing:
                    return False
                self.refreshing = True
        try:
            proc = subprocess.run([str(CTL)] + self.args, capture_output=True, text=True,
                                  timeout=self.timeout)
            if proc.returncode != 0:
                lines = (proc.stderr or "").strip().splitlines() or [f"{self.name} failed"]
                raise RuntimeError(lines[-1][:300])
            data = json.loads(proc.stdout)
            with self.lock:
                self.data, self.fetched_at, self.error = data, time.time(), None
        except Exception as exc:
            with self.lock:
                self.error = f"{type(exc).__name__}: {exc}"[:300]
        finally:
            with self.lock:
                self.refreshing = False
        return True

    def loop(self):
        while True:
            self.refresh()
            time.sleep(self.interval)


# `ctl tail` returns readable lines for a claude -p run, or a screen hardcopy
# (ANSI sequences, NUL padding, mangled box-drawing) for anything else.
_ANSI = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07]*\x07|\x1b[()][A-Z0-9]")
_CTRL = re.compile(r"[\x00-\x08\x0b-\x1f\x7f]")

def clean_tail(raw, limit=200):
    out = []
    for line in _CTRL.sub("", _ANSI.sub("", raw)).splitlines():
        line = line.replace("�", "").rstrip()
        if line.strip():
            out.append(line)
    return out[-limit:]

STATS = {"at": 0, "body": None}
# Each ctl call is a process (tail is an ssh); a page, or a flood from another
# site, must not start them without bound.
CTL_SLOTS = threading.BoundedSemaphore(4)
LOOPBACK = ("localhost", "127.0.0.1", "[::1]", "::1")


def ctl_run(args, timeout):
    if not CTL_SLOTS.acquire(timeout=20):
        raise TimeoutError("dashboard busy")
    try:
        return subprocess.run([str(CTL), *args], capture_output=True, text=True, timeout=timeout, errors="replace")
    finally:
        CTL_SLOTS.release()


def csp_for(page):
    """Only the page's own inline scripts run: an injected handler or script is blocked."""
    import base64, hashlib
    hashes = " ".join(f"'sha256-{base64.b64encode(hashlib.sha256(m.encode()).digest()).decode()}'"
                      for m in re.findall(r"<script>([\s\S]*?)</script>", page))
    return ("default-src 'none'; script-src " + hashes + "; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; "
            "font-src https://fonts.gstatic.com; img-src 'self' data: https://avatars.slack-edge.com https://ca.slack-edge.com "
            "https://secure.gravatar.com; media-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")   # the run-log summary; the log grows once per run, so a minute is fresh enough.
TAIL = {}   # key -> (fetched_at, lines): the agent's own output, on its own cadence.

def agent_tail(key):
    now = time.time()
    hit = TAIL.get(key)
    if hit and now - hit[0] < 4:
        return hit[1]
    branch = key.lower()
    try:
        # --pipeline loads the backend: without it, tail tries a plain ssh and fails on GCE.
        proc = ctl_run(["--pipeline", PIPELINE, "tail", branch], timeout=30)
        lines = clean_tail(proc.stdout or "") if proc.returncode == 0 else \
                [f"(no output: {(proc.stderr or 'tail failed').strip()[:200]})"]
    except Exception as exc:
        lines = [f"(tail failed: {type(exc).__name__})"]
    TAIL[key] = (now, lines)
    if len(TAIL) > 64:   # keys come from requests; keep the cache bounded
        for old in sorted(TAIL, key=lambda k: TAIL[k][0])[:len(TAIL) - 64]:
            TAIL.pop(old, None)
    return lines


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # the page polls; access logs would bury any real error

    def _hardening(self, csp=None):
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", csp or "default-src 'none'; frame-ancestors 'none'")

    def _send(self, code, body, ctype, csp=None):
        payload = body if isinstance(body, bytes) else body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(payload)))
        self._hardening(csp)
        self.end_headers()
        self.wfile.write(payload)

    def _allowed(self, api):
        # Bound to 127.0.0.1, but a page on any origin can still point a name it
        # controls at 127.0.0.1 and read us. Only loopback names are served.
        h = self.headers.get("Host") or ""
        host = h[:h.find("]") + 1] if h.startswith("[") else h.split(":")[0]
        if host not in LOOPBACK:
            self._send(421, json.dumps({"error": "bad host"}), "application/json")
            return False
        # Any site can still fire blind requests at localhost. The API answers
        # only this page: same-origin fetches, or tools that send no browser headers.
        if api:
            from urllib.parse import urlparse
            site, origin = self.headers.get("Sec-Fetch-Site"), self.headers.get("Origin")
            if (site and site not in ("same-origin", "none")) or (origin and urlparse(origin).hostname not in LOOPBACK + ("",)):
                self._send(403, json.dumps({"error": "cross-site request"}), "application/json")
                return False
        return True

    def do_POST(self):
        path = self.path.split("?")[0]
        if not self._allowed(True):
            return
        if path != "/api/refresh":
            self._send(404, json.dumps({"error": "not found"}), "application/json")
            return
        queued = []
        for feed in (AGENTS, FULL):
            with feed.lock:
                busy = feed.refreshing
                if not busy:
                    feed.refreshing = True   # claim it here, atomically
            if not busy:
                threading.Thread(target=feed.refresh, args=(True,), daemon=True).start()
                queued.append(feed.name)
        self._send(202 if queued else 200, json.dumps({"queued": queued}), "application/json")

    def do_GET(self):
        path = self.path.split("?")[0]
        if not self._allowed(path.startswith("/api/")):
            return
        if path in ("/", "/index.html"):
            page = (ROOT / "index.html").read_text()
            self._send(200, page, "text/html; charset=utf-8", csp_for(page))
        elif path == "/icon.png":
            self._send(200, (ROOT / "icon.png").read_bytes(), "image/png")
        elif path == "/api/snapshot":
            snap, age, err, busy = FULL.read()
            ag, ag_age, ag_err, ag_busy = AGENTS.read()
            self._send(200, json.dumps({
                "snapshot": snap, "age_seconds": age, "error": err,
                "agents": ag, "agents_age_seconds": ag_age, "agents_error": ag_err,
                "refreshing": busy or ag_busy,
                "interval": FULL.interval, "agents_interval": AGENTS.interval,
            }), "application/json")
        elif path == "/api/tail":
            from urllib.parse import parse_qs, urlparse
            key = (parse_qs(urlparse(self.path).query).get("key") or [""])[0]
            if not re.fullmatch(r"[A-Za-z][A-Za-z0-9]*-\d+|agent-[a-z0-9]{4,12}", key):
                self._send(400, json.dumps({"error": "bad key"}), "application/json")
            else:
                self._send(200, json.dumps({"key": key, "lines": agent_tail(key)}),
                           "application/json")
        elif path == "/api/media":
            from urllib.parse import parse_qs, urlparse
            q = parse_qs(urlparse(self.path).query)
            key, name = (q.get("key") or [""])[0], (q.get("name") or [""])[0]
            m = re.fullmatch(r"[A-Za-z0-9._-]{1,120}\.(png|jpe?g|gif|webp|mp4|webm)", name)
            f = SESSION_DIR / f"{key}.media" / name
            if not re.fullmatch(r"agent-[a-z0-9]{4,12}", key) or not m or not f.is_file():
                self._send(404, json.dumps({"error": "not found"}), "application/json")
                return
            kind = {"png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
                    "mp4": "video/mp4", "webm": "video/webm"}[m.group(1).lower()]
            data = f.read_bytes()
            # Safari plays video only through byte ranges.
            rng = re.fullmatch(r"bytes=(\d*)-(\d*)", self.headers.get("Range") or "")
            if rng and (rng.group(1) or rng.group(2)):
                start = int(rng.group(1)) if rng.group(1) else max(0, len(data) - int(rng.group(2)))
                end = int(rng.group(2)) if rng.group(1) and rng.group(2) else len(data) - 1
                end = min(end, len(data) - 1)
                if start > end:
                    self.send_response(416); self.send_header("Content-Range", f"bytes */{len(data)}"); self._hardening(); self.end_headers(); return
                part = data[start:end + 1]
                self.send_response(206)
                self.send_header("Content-Type", kind); self.send_header("Content-Length", str(len(part)))
                self.send_header("Content-Range", f"bytes {start}-{end}/{len(data)}"); self.send_header("Accept-Ranges", "bytes")
                self._hardening(); self.end_headers(); self.wfile.write(part); return
            self._send(200, data, kind)
        elif path == "/api/stats":
            now = time.time()
            if not STATS["at"] or now - STATS["at"] > 60:
                try:
                    proc = ctl_run(["--pipeline", PIPELINE, "snapshot", "--stats"], timeout=30)
                    if proc.returncode == 0 and proc.stdout.strip():
                        STATS.update(at=now, body=proc.stdout)
                except Exception:
                    pass
            self._send(200, STATS["body"] or json.dumps({"error": "stats unavailable"}), "application/json")
        elif path == "/api/history":
            from urllib.parse import parse_qs, urlparse
            key = (parse_qs(urlparse(self.path).query).get("key") or [""])[0]
            if not re.fullmatch(r"agent-[a-z0-9]{4,12}", key):
                self._send(400, json.dumps({"error": "bad key"}), "application/json")
                return
            try:
                proc = ctl_run(["session", "history", key], timeout=15)
                body = proc.stdout if proc.returncode == 0 and proc.stdout.strip() else json.dumps({"error": (proc.stderr or "history failed").strip()[:200]})
            except Exception as exc:
                body = json.dumps({"error": type(exc).__name__})
            self._send(200, body, "application/json")
        elif path == "/api/refresh":
            self._send(405, json.dumps({"error": "use POST"}), "application/json")
        else:
            self._send(404, json.dumps({"error": "not found"}), "application/json")


if __name__ == "__main__":
    PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8787
    PIPELINE = sys.argv[2] if len(sys.argv) > 2 else "fxa-ai-fixme"
    INTERVAL = int(sys.argv[3]) if len(sys.argv) > 3 else 120
    AGENTS_INTERVAL = int(sys.argv[4]) if len(sys.argv) > 4 else 30
    FULL = Feed("snapshot", ["--pipeline", PIPELINE, "snapshot"], INTERVAL, 300)
    AGENTS = Feed("agents", ["--pipeline", PIPELINE, "snapshot", "--agents"], AGENTS_INTERVAL, 180)
    threading.Thread(target=FULL.loop, daemon=True).start()
    threading.Thread(target=AGENTS.loop, daemon=True).start()
    print(f"FxA Agent dashboard: http://localhost:{PORT}  (pipeline {PIPELINE}, "
          f"tickets every {INTERVAL}s, agents every {AGENTS_INTERVAL}s)")
    print("Ctrl-C to stop.")
    try:
        ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
    except KeyboardInterrupt:
        print("\nstopped.")
