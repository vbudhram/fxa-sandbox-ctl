#!/usr/bin/env python3
"""Serve the ai-fixme status page from two live feeds.

Two feeds, two cadences. `snapshot --agents` is what the runners are doing:
local files, one rsync and one ssh per runner, tens of seconds. `snapshot` is
the ticket state: Jira and GitHub, a minute or more. Each refreshes on its own
timer in the background, every request is served from the last result at once,
and the page shows how old each result is. A failed refresh keeps the previous
result rather than blanking the page.
"""
import atexit
import base64
import hashlib
import json
import os
import queue
import re
import socket
import subprocess
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parent
CTL = ROOT.parent / "fxa-sandbox-ctl"
SESSION_DIR = Path(os.environ.get("FXA_SESSION_DIR") or Path.home() / ".claude/state/agent-sessions")
ERRORS_FILE = os.environ.get("FXA_ERRORS_FILE") or str(Path.home() / ".claude/state/fxa-ai-fixme/errors.jsonl")
PROFILES_DIR = ROOT.parent / "profiles"
sys.path.insert(0, str(ROOT.parent / "lib"))
import fxadb  # noqa: E402  the controller's store: sessions as they change


class Feed:
    """Last good result of one command, plus what happened on the latest attempt."""
    def __init__(self, name, args, interval, timeout):
        self.name, self.args, self.interval, self.timeout = name, args, interval, timeout
        self.lock = threading.Lock()
        self.data = None          # last SUCCESSFUL result
        self.fetched_at = None    # when that succeeded
        self.error = None         # error from the most recent attempt, if any
        self.refreshing = False
        self.fails = 0            # failures in a row; the third raises an alert
        self.alerted = False

    def read(self):
        with self.lock:
            age = None if self.fetched_at is None else round(time.time() - self.fetched_at)
            return self.data, age, self.error, self.refreshing

    def claim(self):
        """Mark a refresh in flight; False when one already is."""
        with self.lock:
            if self.refreshing:
                return False
            self.refreshing = True
            return True

    def refresh(self, already_claimed=False):
        """Returns False when a refresh was already in flight and this one did nothing."""
        if not already_claimed and not self.claim():
            return False
        try:
            proc = subprocess.run([str(CTL)] + self.args, capture_output=True, text=True,
                                  timeout=self.timeout)
            if proc.returncode != 0:
                lines = (proc.stderr or "").strip().splitlines() or [f"{self.name} failed"]
                raise RuntimeError(lines[-1][:300])
            data = json.loads(proc.stdout)
            with self.lock:
                self.data, self.fetched_at, self.error = data, time.time(), None
            self.fails = 0
            if self.alerted:
                self.alerted = False
                threading.Thread(target=feed_alert_clear, args=(self.name,), daemon=True).start()
        except Exception as exc:
            with self.lock:
                self.error = f"{type(exc).__name__}: {exc}"[:300]
            self.fails += 1
            if self.fails == 3:
                self.alerted = True
                feed_alert(self.name, self.error)
        finally:
            with self.lock:
                self.refreshing = False
        return True

    def loop(self):
        while True:
            self.refresh()
            time.sleep(self.interval)


# A feed that keeps failing leaves the page empty with no other sign (the sessions
# feed failed every refresh on 2026-10-03). The third failure in a row goes to the
# error log, which DMs the operator; the next success resolves it.
def _feed_sig(name):
    return hashlib.sha1(f"dashboard|feed_failed|{name}".encode()).hexdigest()[:10]


def feed_alert(name, error):
    line = {"at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "source": "dashboard", "kind": "feed_failed", "key": None,
            "where": "dashboard", "message": f"the dashboard's {name} feed failed 3 times in a row; the page shows no fresh {name} data",
            "log": (error or "")[:300], "sig": _feed_sig(name)}
    try:
        os.makedirs(os.path.dirname(ERRORS_FILE), exist_ok=True)
        with open(ERRORS_FILE, "a") as f:
            f.write(json.dumps(line, separators=(",", ":")) + "\n")
    except OSError:
        pass
    fxadb.ingest("errors", line)


def feed_alert_clear(name):
    try:
        ctl_run(["errors", "resolve", _feed_sig(name), f"the {name} feed works again"], timeout=30)
    except Exception:
        pass


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

ERRORS = {"at": 0, "body": None}
# Each ctl call is a process (tail is an ssh); a page, or a flood from another
# site, must not start them without bound.
CTL_SLOTS = threading.BoundedSemaphore(4)
LOOPBACK = ("localhost", "127.0.0.1", "[::1]", "::1")
# Names a trusted proxy on this host serves us under, such as `tailscale serve`
# (FXA_DASHBOARD_HOSTS=my-mac.tailnet.ts.net). Only these, never a wildcard.
EXTRA_HOSTS = tuple(h.strip().lower() for h in os.environ.get("FXA_DASHBOARD_HOSTS", "").split(",") if h.strip())
SERVED_AS = LOOPBACK + EXTRA_HOSTS


def ctl_run(args, timeout):
    if not CTL_SLOTS.acquire(timeout=20):
        raise TimeoutError("dashboard busy")
    try:
        return subprocess.run([str(CTL), *args], capture_output=True, text=True, timeout=timeout, errors="replace")
    finally:
        CTL_SLOTS.release()


def cached_ctl(cache, args, timeout, max_age):
    """Last good stdout of a ctl call, rerun when older than max_age; a failure keeps the old body."""
    now = time.time()
    if not cache["at"] or now - cache["at"] > max_age:
        try:
            proc = ctl_run(args, timeout=timeout)
            if proc.returncode == 0 and proc.stdout.strip():
                cache.update(at=now, body=proc.stdout)
        except Exception:
            pass
    return cache["body"]


DESKTOPS = {}  # session key -> (tunnel process, local port, VNC password)
DESKTOP_LOCK = threading.Lock()


def desktop(key):
    """Start a session's desktop and a loopback tunnel to its noVNC; reuse both while the tunnel lives."""
    # ponytail: one lock for all desktops; a second first-open waits for the first.
    with DESKTOP_LOCK:
        cur = DESKTOPS.get(key)
        if cur and cur[0].poll() is None:
            return cur[1], cur[2]
        proc = ctl_run(["session", "desktop", key], timeout=300)
        m = re.search(r"^password=([A-Za-z0-9]{8})$", proc.stdout, re.M)
        if proc.returncode != 0 or not m:
            raise RuntimeError((proc.stderr or "the desktop did not start").strip()[-300:])
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        tunnel = subprocess.Popen([str(CTL), "session", "tunnel", key, str(port)], stdin=subprocess.DEVNULL,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        for _ in range(60):
            if tunnel.poll() is not None:
                raise RuntimeError("the tunnel to the sandbox did not start")
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{port}/fxa.html", timeout=2).close()
                break
            except OSError:
                time.sleep(0.5)
        DESKTOPS[key] = (tunnel, port, m.group(1))
        return port, m.group(1)


def close_desktops():
    for tunnel, _, _ in DESKTOPS.values():
        tunnel.terminate()


def csp_for(page):
    """Only the page's own inline scripts run: an injected handler or script is blocked."""
    hashes = " ".join(f"'sha256-{base64.b64encode(hashlib.sha256(m.encode()).digest()).decode()}'"
                      for m in re.findall(r"<script>([\s\S]*?)</script>", page))
    return ("default-src 'none'; script-src " + hashes + "; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; "
            "font-src https://fonts.gstatic.com; img-src 'self' data: https://avatars.slack-edge.com https://ca.slack-edge.com "
            "https://secure.gravatar.com; media-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")


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


WATCHERS = threading.BoundedSemaphore(16)  # each is one ssh to a runner


def watch_session(thread):
    """A Slack thread's newest session as (key, state), or None."""
    try:
        rec = json.loads((SESSION_DIR / f"thread-{thread.replace(':', '-', 1)}.json").read_text())
        key = (rec.get("sessions") or "").split()[-1]
        return key, json.loads((SESSION_DIR / f"{key}.json").read_text()).get("state")
    except (OSError, ValueError, IndexError):
        return None


# Only these keys are read: the file also holds the bot's tokens.
ACCESS_LINE = re.compile(r"^PROFILE_(USERS|OPEN|CHANNELS|JIRA)=(.*)$")


def _pairs(v):
    """Like the bot's profile.js pairs(): comma-separated k:v, empty parts dropped."""
    out = {}
    for part in v.split(","):
        kv = part.strip().split(":")
        if len(kv) == 2 and kv[0] and kv[1]:
            out[kv[0]] = kv[1]
    return out


def read_access():
    """The bot's PROFILE_* team rules from bot.env.base, as (rules, None) or (None, error)."""
    path = os.environ.get("FXA_BOT_ENV_BASE") or str(Path.home() / ".config/fxa/bot.env.base")
    try:
        with open(path) as f:
            raw = {m.group(1): m.group(2).strip().strip("'\"") for m in map(ACCESS_LINE.match, f) if m}
        mtime = int(os.path.getmtime(path))
    except (OSError, ValueError) as exc:
        return None, type(exc).__name__
    return {"open": {x.strip() for x in raw.get("OPEN", "").split(",") if x.strip()},
            "users": {k: [u for u in v.split("+") if u] for k, v in _pairs(raw.get("USERS", "")).items()},
            "channels": _pairs(raw.get("CHANNELS", "")), "jira": _pairs(raw.get("JIRA", "")),
            "path": path, "mtime": mtime}, None


def team_access(profile, access):
    """One team's rules; users is a count, so no Slack user ID leaves the server."""
    if access is None:
        return None
    return {"open": "built-in" if profile == "fxa" else profile in access["open"],
            "users": len(access["users"].get(profile, [])),
            "channels": sum(1 for p in access["channels"].values() if p == profile),
            "jira": sorted(k for k, p in access["jira"].items() if p == profile)}


def team_issues(teams, access):
    """(issues per team, in order; top-level issues). Pure, so the offline check can prove the rules."""
    per = []
    for t in teams:
        if t.get("load_error"):
            per.append([{"level": "bad", "text": "profile.conf did not load", "key": "profile.conf"}])
            continue
        out = []
        if not t.get("read_only"):
            for r in t.get("repos") or []:
                if r.get("role") == "work" and not r.get("write"):
                    why = r.get("why") or "no write"
                    out.append({"level": "info", "text": f"{r.get('slug')}: " + ("GitHub App check failed; write unknown"
                                if why == "the GitHub App check failed" else why),
                                "key": "PIPE_REPO_SLUG" if t["profile"] == "fxa" else "PIPE_REPOS"})
        a = team_access(t["profile"], access)
        if a and t["profile"] != "fxa" and not a["open"] and not a["users"]:
            out.append({"level": "warn", "text": "nobody can start it", "key": "PROFILE_USERS"})
        per.append(out)
    top = []
    if access is not None:
        names = {t["profile"] for t in teams}
        # A name that is not profile-shaped may be a Slack user ID typed in the wrong place, so never show it.
        orphan = lambda key, p: {"level": "warn", "key": key, "text": f"{key} names unknown team '{p}'"
                                 if re.fullmatch(r"[a-z0-9][a-z0-9_-]*", p) else f"{key} has an entry that is not a team name"}
        top += [orphan("PROFILE_OPEN", p) for p in sorted(access["open"] - names)]
        top += [orphan("PROFILE_USERS", p) for p in sorted(set(access["users"]) - names)]
        for key in ("CHANNELS", "JIRA"):
            top += [orphan("PROFILE_" + key, p) for p in sorted(access[key.lower()].values()) if p not in names]
    return per, top


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

    def _json(self, code, obj):
        self._send(code, json.dumps(obj), "application/json")

    def _allowed(self, api):
        # Bound to 127.0.0.1, but a page on any origin can still point a name it
        # controls at 127.0.0.1 and read us. Only loopback names are served.
        h = self.headers.get("Host") or ""
        host = h[:h.find("]") + 1] if h.startswith("[") else h.split(":")[0]
        if host.lower() not in SERVED_AS:
            self._json(421, {"error": "bad host"})
            return False
        # Any site can still fire blind requests at localhost. The API answers
        # only this page: same-origin fetches, or tools that send no browser headers.
        if api:
            site, origin = self.headers.get("Sec-Fetch-Site"), self.headers.get("Origin")
            if (site and site not in ("same-origin", "none")) or (origin and urlparse(origin).hostname not in SERVED_AS + ("",)):
                self._json(403, {"error": "cross-site request"})
                return False
        return True

    def _desktop(self, key):
        if not re.fullmatch(r"agent-[a-z0-9]{4,12}", key):
            self._json(400, {"error": "bad key"})
            return
        # Opening a desktop starts things on the runner. Another site may link
        # here, but only a click on this server's own page goes through.
        if self.headers.get("Sec-Fetch-Site") not in (None, "none", "same-origin"):
            page = (f'<!doctype html><meta charset="utf-8"><title>Open desktop</title>'
                    f'<body style="font:16px system-ui;margin:3em"><p>Open the Linux desktop of session <b>{key}</b>?</p>'
                    f'<p><a href="/desktop/{key}">Open desktop</a></p>')
            self._send(200, page, "text/html; charset=utf-8", "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'")
            return
        try:
            port, password = desktop(key)
        except Exception as exc:
            self._send(502, f"Could not open the desktop: {exc}", "text/plain; charset=utf-8")
            return
        self.send_response(302)
        # The password rides in the fragment, which the browser never sends to a server.
        self.send_header("Location", f"http://localhost:{port}/fxa.html#password={password}")
        self._hardening()
        self.end_headers()

    def _lesson_decide(self):
        # JSON only: a cross-site form cannot send it without a preflight, which this server never answers.
        if (self.headers.get("Content-Type") or "").split(";")[0].strip() != "application/json":
            self._json(415, {"error": "send JSON"})
            return
        try:
            body = json.loads(self.rfile.read(min(int(self.headers.get("Content-Length") or 0), 4096)) or b"{}")
        except (ValueError, json.JSONDecodeError):
            self._json(400, {"error": "bad JSON"})
            return
        lid, action, text = body.get("id"), body.get("action"), body.get("text") or ""
        if not (isinstance(lid, str) and re.fullmatch(r"[0-9a-f]{8}", lid)) or action not in ("approve", "reject") \
                or not isinstance(text, str) or len(text) > 300:
            self._json(400, {"error": "bad request"})
            return
        try:
            proc = ctl_run(["lessons", action, lid] + (["--text", text] if text.strip() and action == "approve" else []), timeout=15)
        except Exception as exc:
            self._json(503, {"error": type(exc).__name__})
            return
        if proc.returncode != 0:
            self._json(400, {"error": (proc.stderr or "failed").strip()[:200]})
            return
        self._json(200, {"ok": True})

    def do_POST(self):
        path = self.path.split("?")[0]
        if not self._allowed(True):
            return
        if path == "/api/lessons":
            self._lesson_decide()
            return
        if path != "/api/refresh":
            self._json(404, {"error": "not found"})
            return
        queued = []
        for feed in (AGENTS, FULL):
            if feed.claim():
                threading.Thread(target=feed.refresh, args=(True,), daemon=True).start()
                queued.append(feed.name)
        self._json(202 if queued else 200, {"queued": queued})

    def _watch_events(self, thread):
        """Server-sent events for the gateway's /w/<thread> page: the session, then its view lines live."""
        if not re.fullmatch(r"[A-Z0-9]+:\d+\.\d+", thread):
            self._json(400, {"error": "bad thread"})
            return
        found = watch_session(thread)
        if not found:
            self._json(404, {"error": "no session in this thread yet"})
            return
        if not WATCHERS.acquire(blocking=False):
            self._json(503, {"error": "too many watchers; try again soon"})
            return
        key, state = found
        proc = None
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(f"event: session\ndata: {json.dumps({'key': key, 'state': state})}\n\n".encode())
            self.wfile.flush()
            if state in ("starting", "active"):
                proc = subprocess.Popen([str(CTL), "--pipeline", PIPELINE, "view", key], stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, text=True, errors="replace", start_new_session=True)
                lines = queue.Queue()

                def pump():
                    for ln in proc.stdout:
                        lines.put(ln)
                    lines.put(None)
                threading.Thread(target=pump, daemon=True).start()
                while True:
                    try:
                        ln = lines.get(timeout=15)
                    except queue.Empty:
                        ln = ""  # a comment keeps proxies from closing an idle stream
                    if ln is None:
                        break
                    self.wfile.write((f"data: {ln.strip()}\n\n" if ln else ": ping\n\n").encode())
                    self.wfile.flush()
            self.wfile.write(b"event: end\ndata: {}\n\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass  # the viewer left
        finally:
            if proc:
                try:
                    os.killpg(proc.pid, 15)  # the ctl, its ssh and jq
                except OSError:
                    pass  # already gone (macOS says EPERM for an exited group)
                proc.wait()
            WATCHERS.release()

    def do_GET(self):
        path = self.path.split("?")[0]
        if not self._allowed(path.startswith("/api/")):
            return
        query = parse_qs(urlparse(self.path).query)
        arg = lambda name: (query.get(name) or [""])[0]
        if path in ("/", "/index.html"):
            page = (ROOT / "index.html").read_text()
            self._send(200, page, "text/html; charset=utf-8", csp_for(page))
        elif path == "/icon.png":
            self._send(200, (ROOT / "icon.png").read_bytes(), "image/png")
        elif path == "/api/snapshot":
            snap, age, err, busy = FULL.read()
            ag, ag_age, ag_err, ag_busy = AGENTS.read()
            self._json(200, {
                "snapshot": snap, "age_seconds": age, "error": err,
                "agents": ag, "agents_age_seconds": ag_age, "agents_error": ag_err,
                "refreshing": busy or ag_busy,
                "interval": FULL.interval, "agents_interval": AGENTS.interval,
            })
        elif path == "/api/tail":
            key = arg("key")
            if not re.fullmatch(r"[A-Za-z][A-Za-z0-9]*-\d+|agent-[a-z0-9]{4,12}", key):
                self._json(400, {"error": "bad key"})
            else:
                self._json(200, {"key": key, "lines": agent_tail(key)})
        elif path == "/api/watch/events":
            self._watch_events(arg("thread"))
        elif path == "/api/media":
            key, name = arg("key"), arg("name")
            m = re.fullmatch(r"[A-Za-z0-9._-]{1,120}\.(png|jpe?g|gif|webp|mp4|webm)", name)
            f = SESSION_DIR / f"{key}.media" / name
            if not re.fullmatch(r"agent-[a-z0-9]{4,12}", key) or not m or not f.is_file():
                self._json(404, {"error": "not found"})
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
        elif path == "/api/sessions":
            # Sessions written since the page's cursor, from the store: milliseconds, so the
            # page asks every few seconds. No store: an empty answer, and the feeds carry on.
            since = arg("since")
            try:
                if not os.path.exists(fxadb.PATH):
                    raise FileNotFoundError(fxadb.PATH)
                con = fxadb.connect(readonly=True)
                try:
                    body = fxadb.sessions_since(con, int(since) if since.isdigit() else None, str(SESSION_DIR))
                finally:
                    con.close()
            except Exception as exc:
                body = {"cursor": None, "rows": [], "error": type(exc).__name__}
            self._json(200, body)
        elif path == "/api/usage":
            # One session's or quick answer's LLM use by model, from the proxy's calls in the store.
            run = arg("run")
            if not re.fullmatch(r"(agent|ask)-[a-z0-9]{4,12}", run):
                self._json(400, {"error": "bad run"})
                return
            try:
                con = fxadb.connect(readonly=True)
                try:
                    self._json(200, {"run": run, "models": fxadb.usage_by_model(con, run)})
                finally:
                    con.close()
            except Exception as exc:
                self._json(200, {"run": run, "models": [], "error": type(exc).__name__})
        elif path == "/api/stats":
            data = STATS.read()[0]
            self._json(200, data if data is not None else {"error": "stats unavailable"})
        elif path == "/api/teams":
            data, age, err, busy = TEAMS.read()
            access, access_err = read_access()
            teams = []
            if data is not None:  # the diff needs the list; before it, every dir would look broken
                listed = {t.get("profile") for t in data}
                teams = [dict(t, access=team_access(t.get("profile"), access)) for t in data]
                teams += [{"profile": d, "load_error": True}
                          for d in sorted(p.parent.name for p in PROFILES_DIR.glob("*/profile.conf")) if d not in listed]
            per, top = team_issues(teams, access if data is not None else None)
            self._json(200, {"teams": [dict(t, issues=i) for t, i in zip(teams, per)], "issues": top,
                             "access_source": access and {"path": access["path"], "mtime": access["mtime"]},
                             "access_error": access_err, "age_seconds": age, "error": err,
                             "refreshing": busy, "interval": TEAMS.interval})
        elif path == "/api/lessons":
            try:
                proc = ctl_run(["lessons", "--json"], timeout=15)
                body = proc.stdout if proc.returncode == 0 and proc.stdout.strip() else "[]"
            except Exception:
                body = "[]"
            self._send(200, body, "application/json")
        elif path == "/api/errors":
            self._send(200, cached_ctl(ERRORS, ["errors", "--json"], 20, 20) or "[]", "application/json")
        elif path == "/api/history":
            key = arg("key")
            if not re.fullmatch(r"agent-[a-z0-9]{4,12}", key):
                self._json(400, {"error": "bad key"})
                return
            try:
                proc = ctl_run(["session", "history", key], timeout=15)
                body = proc.stdout if proc.returncode == 0 and proc.stdout.strip() else json.dumps({"error": (proc.stderr or "history failed").strip()[:200]})
            except Exception as exc:
                body = json.dumps({"error": type(exc).__name__})
            self._send(200, body, "application/json")
        elif path.startswith("/desktop/"):
            self._desktop(path[len("/desktop/"):])
        elif path == "/api/refresh":
            self._json(405, {"error": "use POST"})
        else:
            self._json(404, {"error": "not found"})


if __name__ == "__main__":
    PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8787
    PIPELINE = sys.argv[2] if len(sys.argv) > 2 else "fxa-ai-fixme"
    INTERVAL = int(sys.argv[3]) if len(sys.argv) > 3 else 120
    AGENTS_INTERVAL = int(sys.argv[4]) if len(sys.argv) > 4 else 30
    FULL = Feed("snapshot", ["--pipeline", PIPELINE, "snapshot"], INTERVAL, 300)
    AGENTS = Feed("agents", ["--pipeline", PIPELINE, "snapshot", "--agents"], AGENTS_INTERVAL, 180)
    threading.Thread(target=FULL.loop, daemon=True).start()
    # The run logs grow once per run, so a minute is fresh enough; no request waits for a refresh.
    STATS = Feed("stats", ["--pipeline", PIPELINE, "snapshot", "--stats"], 60, 30)
    threading.Thread(target=AGENTS.loop, daemon=True).start()
    threading.Thread(target=STATS.loop, daemon=True).start()
    # Each team runs pipeline_load and the App check; outside CTL_SLOTS like the other feeds.
    TEAMS = Feed("teams", ["profile", "list"], 300, 600)
    threading.Thread(target=TEAMS.loop, daemon=True).start()
    print(f"FxA Agent dashboard: http://localhost:{PORT}  (pipeline {PIPELINE}, "
          f"tickets every {INTERVAL}s, agents every {AGENTS_INTERVAL}s)")
    print("Ctrl-C to stop.")
    atexit.register(close_desktops)
    try:
        # 127.0.0.1 unless told otherwise: on the manager VM the Cloud Run gateway
        # reaches it on the private network, and a GCP firewall rule admits only it.
        ThreadingHTTPServer((os.environ.get("FXA_DASHBOARD_BIND") or "127.0.0.1", PORT), Handler).serve_forever()
    except KeyboardInterrupt:
        print("\nstopped.")
