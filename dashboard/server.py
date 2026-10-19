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
import hmac
import json
import os
import queue
import re
import socket
import subprocess
import sys
import tempfile
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
import routine  # noqa: E402  the one reader of a team's spend against its caps


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


def ctl_run(args, timeout, env=None, input=None):
    if not CTL_SLOTS.acquire(timeout=20):
        raise TimeoutError("dashboard busy")
    try:
        return subprocess.run([str(CTL), *args], capture_output=True, text=True, timeout=timeout, errors="replace",
                              env={**os.environ, **env} if env else None, input=input)
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


# Known token formats, masked in every API reply: tail, history and the snapshot carry agent text
# and commands, and the page is open to anyone IAP admits. The same pattern as _SESSION_VIEW_JQ.
MASK = re.compile(r"(sk-ant-[a-z0-9]+-|fxl_|fxm_|xox[abpr]-|xapp-|ghs_|ghp_|gho_|github_pat_)[A-Za-z0-9_-]{8,}")

TAIL = {}   # key -> (fetched_at, lines): the agent's own output, on its own cadence.

JOB_TITLES = {"pass": "Pipeline pass", "triage": "Triage", "merge-watch": "Merge watch"}


def recent_runs(rows, snap, now, limit, days, state_dir, sess_dir, hide, admin=False):
    """The newest runs of the stats feed's rows, with a title and an outcome each.
    Titles and PR numbers come from the snapshot; a secured ticket shows no title or PR; hide(team) drops a run."""
    titles, prs = {}, {}
    for k in ("blocked", "inflight", "review", "open_prs", "merged_prs"):
        for i in (snap or {}).get(k) or []:
            if isinstance(i, dict) and i.get("key"):
                titles.setdefault(i["key"], i.get("summary") or i.get("title"))
                n = i.get("number") or i.get("pr")
                if n:
                    prs.setdefault(i["key"], (n, "merged" if k == "merged_prs" else "open"))
    for v in ((snap or {}).get("queue") or {}).values():
        for i in v if isinstance(v, list) else []:
            if isinstance(i, dict) and i.get("key"):
                titles.setdefault(i["key"], i.get("summary"))
    repo = (snap or {}).get("repo") or "mozilla/fxa"
    since = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now - days * 86400))
    out = []
    for r in sorted((r for r in rows or [] if (r.get("at") or "") >= since), key=lambda r: r["at"], reverse=True):
        team = r.get("profile") or "fxa"
        # Passes run every 5 min and would fill the list; the system card shows them.
        if hide(team) or r.get("src") == "pass":
            continue
        src, key, kind = r.get("src"), r.get("key") or "", r.get("kind") or ""
        num = state = None
        if src == "pipeline":
            title = titles.get(key) or key
            if r.get("pr") and key in prs:
                num, state = prs[key]
            outcome = "pr" if r.get("pr") else "no_pr"
            if os.path.exists(os.path.join(state_dir, key + ".secured-noted")):
                title, num, state = "Secured ticket", None, None
        elif src == "slack":
            try:
                with open(os.path.join(sess_dir, key + ".prompt.md"), "rb") as f:
                    title = f.read(300).decode("utf-8", "ignore").strip().split("\n")[0][:120] or "Slack session"
            except OSError:
                title = "Slack session"
            num = r.get("prn")
            # A routine's prompt and session are a team admin's, as on Running now and Stats.
            try:
                with open(os.path.join(sess_dir, key + ".json")) as f:
                    routine = bool(json.load(f).get("routine_run"))
            except (OSError, ValueError):
                routine = False
            if routine and not admin:
                title, key, num = "Scheduled run", "", None
            outcome = "running" if r.get("live") else "pr" if num else "answered"
        elif src == "answer":
            title, outcome = "Quick answer", "failed" if kind == "failed" else "answered"
        else:
            title, outcome = JOB_TITLES.get(kind, kind.capitalize() or "Job"), "done"
        url = num and f"https://github.com/{r.get('prr') or repo}/pull/{num}"
        out.append({"at": r["at"], "src": src, "kind": kind, "key": key, "title": title, "team": team, "outcome": outcome,
                    "pr_url": url or None, "pr_number": num, "pr_state": state, "usd": r.get("usd"), "min": r.get("min")})
        if len(out) >= limit:
            break
    return out


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
    """A Slack thread's newest session as (key, state, profile, narrow), or None. narrow: the record's own
    watch_narrow (a routine's security review, D9)."""
    try:
        rec = json.loads((SESSION_DIR / f"thread-{thread.replace(':', '-', 1)}.json").read_text())
        key = (rec.get("sessions") or "").split()[-1]
        s = json.loads((SESSION_DIR / f"{key}.json").read_text())
        return key, s.get("state"), s.get("profile") or "fxa", str(s.get("watch_narrow") or "") == "1"
    except (OSError, ValueError, IndexError):
        return None


_PRIVATE = {}  # profile -> (when, private)


def team_private(profile):
    """True when the team has a private repo (profile show), cached 10 minutes. No answer counts as private."""
    hit = _PRIVATE.get(profile)
    if hit and time.time() - hit[0] < 600:
        return hit[1]
    try:
        out = subprocess.run([str(CTL), "--pipeline", profile, "profile", "show"], capture_output=True, text=True, timeout=60)
        private = out.returncode != 0 or json.loads(out.stdout).get("private") is not False
    except (OSError, ValueError, subprocess.SubprocessError):
        private = True
    _PRIVATE[profile] = (time.time(), private)
    return private


def watch_narrow(profile, channel, access, records, gates, narrow=False):
    """True when the session itself is narrowed (its record has watch_narrow 1), its team is not open (FxA
    always is), or its channel is in the bot's CHANNEL_GATES. gates None (the bot .env unreadable) counts as gated."""
    t = team_access(profile, access, records)
    gated = profile != "fxa" and not (t or {}).get("open")
    return narrow or gated or gates is None or channel in gates


def read_gates():
    """The channels the bot's CHANNEL_GATES lists (channel:source pairs), or None when the .env cannot be read."""
    path = os.environ.get("FXA_BOT_ENV") or str(ROOT.parent.parent / "fxa-agent-bot" / ".env")
    line = ""
    try:
        with open(path) as f:
            for l in f:  # the last one wins, as in node --env-file
                if l.startswith("CHANNEL_GATES="):
                    line = l.split("=", 1)[1].strip().strip("'\"")
    except (OSError, ValueError):
        return None
    return set(_pairs(line))


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
    """The bot's PROFILE_* team rules from the .env it starts with, as (rules, None) or (None, error)."""
    # The running bot's file (node --env-file=.env), not bot.env.base: an edit on the VM goes only there.
    path = os.environ.get("FXA_BOT_ENV") or str(ROOT.parent.parent / "fxa-agent-bot" / ".env")
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


# The key the gateway signs each request's user with (secret fxa-dashboard-hmac, written by fxa-secrets).
HMAC_FILE = Path(os.environ.get("FXA_DASHBOARD_HMAC_FILE") or Path.home() / ".config/fxa/dashboard-hmac")
SIGN_WINDOW_S = 60
EMAIL = re.compile(r"[^@\s|]{1,64}@[A-Za-z0-9.-]{1,190}\.[A-Za-z]{2,}")
TEAM_NAME = r"[a-z][a-z0-9-]{1,30}"


def read_hmac_key():
    try:
        return HMAC_FILE.read_bytes().strip()
    except OSError:
        return b""


def signed_user(headers, method, path, key, now):
    """The email the gateway signed for this method and path (desktop-gateway sign_user), or None."""
    email, ts, sig = (headers.get(h) or "" for h in ("X-Fxa-User", "X-Fxa-Time", "X-Fxa-Sig"))
    if not key or not EMAIL.fullmatch(email) or not ts.isdigit() or abs(now - int(ts)) > SIGN_WINDOW_S:
        return None
    want = hmac.new(key, f"{email}|{ts}|{method}|{path}".encode(), hashlib.sha256).hexdigest()
    return email.lower() if hmac.compare_digest(want, sig) else None


def team_admins():
    """TEAM_ADMINS from the ctl .env: the emails that may change teams. Empty: nobody."""
    return {e.strip().lower() for e in os.environ.get("TEAM_ADMINS", "").split(",") if e.strip()}


# What a private team's session keeps from a viewer who is not a team admin: its words and its screen.
PRIVATE_FIELDS = ("request", "media", "last_text", "last_tool")


def session_private(key):
    """True when the session's team has a private repo; a record that cannot be read counts as private."""
    try:
        rec = json.loads((SESSION_DIR / f"{key}.json").read_text())
    except (OSError, ValueError):
        return True
    return not isinstance(rec, dict) or team_private(rec.get("profile") or "fxa")


def redact_session(s):
    """A copy of a session row without PRIVATE_FIELDS, also inside its live agent."""
    out = {k: v for k, v in s.items() if k not in PRIVATE_FIELDS}
    if isinstance(out.get("agent"), dict):
        out["agent"] = {k: v for k, v in out["agent"].items() if k not in PRIVATE_FIELDS}
    return out


def read_records():
    """The team records' access, from the controller's teams index (lib/teams.sh), or {}."""
    path = os.path.join(os.environ.get("FXA_TEAMS_DIR") or os.path.expanduser("~/.claude/state/teams"), "index.json")
    try:
        with open(path) as f:
            teams = json.load(f).get("teams", {})
        return teams if isinstance(teams, dict) else {}
    except (OSError, ValueError, AttributeError):
        return {}


TEST_TIMEOUT = 3600  # a profile test boots one runner; a log older than this is not a test that runs


def team_budget(profile, now):
    """(this month's and today's spend against the caps, or None; a fixed error word, or None). The path is
    built only for a profile-shaped name, and an error never carries its text (it may name a path)."""
    if not re.fullmatch(TEAM_NAME, profile or ""):
        return None, None
    d = os.path.join(os.environ.get("FXA_LLM_PROXY_DIR") or os.path.expanduser("~/.claude/state/llm-proxy"), "teams")
    if not os.path.isdir(d):
        return None, None
    try:
        return routine.spend_state(f"{d}/{profile}.json", f"{d}/{profile}.spend.json", now), None
    except Exception:  # noqa: BLE001
        return None, "unreadable"


def team_test(name, now):
    """The last profile test of a record team: {result, at, generation, tested}, or None for a team with no
    record. Only the exact final lines of teams.sh count, and only from a log not older than the record's
    generation: test output can carry runner text, and old files survive a delete and re-create."""
    teams = Path(os.environ.get("FXA_TEAMS_DIR") or Path.home() / ".claude/state/teams")
    if not re.fullmatch(TEAM_NAME, name or "") or not (teams / f"{name}.json").exists():
        return None
    mt = lambda p: p.stat().st_mtime if p.exists() else None
    num = lambda p: int(p.read_text().strip()) if p.exists() and p.read_text().strip().isdigit() else None
    gen_p, log, pidf, tp = (teams / f"{name}{e}" for e in (".gen", ".test.log", ".test.pid", ".tested"))
    gen, gm = num(gen_p), mt(gen_p) or 0
    # tested is read by value: Activate writes a new generation after the test, so its file is older by design.
    # A delete removes the test files, so a re-created name starts with none.
    out = {"result": None, "at": None, "generation": gen, "tested": num(tp)}
    lm = mt(log)
    if lm is None or lm < gm:
        return out
    lines = [x for x in log.read_text(errors="replace").splitlines() if x.strip()]
    last = lines[-1] if lines else ""
    m = re.fullmatch(rf"passed: team {re.escape(name)} may be activated at generation (\d+)", last)
    if m:
        if gen is not None and int(m.group(1)) == gen:
            out.update(result="passed", at=int(lm))
    elif last == f"failed: team {name} stays as it is":
        out.update(result="failed", at=int(lm))
    elif lm > now - TEST_TIMEOUT:
        try:
            os.kill(int(pidf.read_text()), 0)
            out.update(result="running", at=int(lm))
        except (OSError, ValueError):
            pass
    return out


def team_access(profile, access, records=None):
    """One team's rules; users is a count, so no Slack user ID leaves the server."""
    rec = (records or {}).get(profile)
    if isinstance(rec, dict):  # a record team: its own rules, and nobody can start it unless it is active
        a = rec.get("access") or {}
        active = rec.get("status") == "active"
        return {"open": active and a.get("open") is True, "users": len(a.get("users") or []) if active else 0,
                "channels": len(a.get("channels") or []),
                "jira": sorted(set(a.get("jira_prefixes") or []) | ({rec["jira"]} if rec.get("jira") else set())),
                "record": True, "status": rec.get("status") or "draft"}
    if access is None:
        return None
    return {"open": "built-in" if profile == "fxa" else profile in access["open"],
            "users": len(access["users"].get(profile, [])),
            "channels": sum(1 for p in access["channels"].values() if p == profile),
            "jira": sorted(k for k, p in access["jira"].items() if p == profile)}


def team_issues(teams, access, records=None):
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
        a = team_access(t["profile"], access, records)
        if a and t["profile"] != "fxa" and not a["open"] and not a["users"]:
            out.append({"level": "warn", "text": "nobody can start it", "key": "PROFILE_USERS"})
        # Spend: a reached cap refuses every session and run of the team; 90% is a heads-up.
        b = t.get("budget")
        if t.get("budget_error"):
            out.append({"level": "info", "text": "spend cannot be read", "key": "llm-proxy/teams"})
        elif b:
            for k, label in (("day", "daily"), ("month", "monthly")):
                cap = b.get(f"{k}_cap")
                if cap and b[f"{k}_usd"] >= cap:
                    out.append({"level": "warn", "text": f"{label} spend cap reached", "key": "llm-proxy/teams"})
                elif cap and b[f"{k}_usd"] >= 0.9 * cap:
                    out.append({"level": "info", "text": f"{label} spend at {round(100 * b[k + '_usd'] / cap)}% of the cap", "key": "llm-proxy/teams"})
        tst, rec = t.get("test") or {}, (records or {}).get(t["profile"])
        if isinstance(rec, dict) and rec.get("status") == "active" and tst.get("tested") is not None and str(rec.get("generation") or "") not in ("", str(tst["tested"])):
            out.append({"level": "info", "text": f"last passed at generation {tst['tested']}; later edits did not change what a runner uses", "key": "profile test"})
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
        if ctype == "application/json":
            body = MASK.sub(r"\1<masked>", body.decode("utf-8") if isinstance(body, bytes) else body)
        payload = body if isinstance(body, bytes) else body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(payload)))
        self._hardening(csp)
        self.end_headers()
        self.wfile.write(payload)

    def _json(self, code, obj):
        self._send(code, json.dumps(obj), "application/json")

    def _team_admin(self, path):
        """True when the gateway signed this GET for a team admin, as /api/lessons checks."""
        return signed_user(self.headers, "GET", path, read_hmac_key(), int(time.time())) in team_admins()

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
        # An approved lesson goes into every new runner's guide, so only a signed team admin may decide one.
        user = self._admin("POST", "/api/lessons")
        if not user:
            return
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
            proc = ctl_run(["lessons", action, lid] + (["--text", text] if text.strip() and action == "approve" else []), timeout=15,
                           env={"FXA_TEAM_ACTOR": user})
        except Exception as exc:
            self._json(503, {"error": type(exc).__name__})
            return
        if proc.returncode != 0:
            self._json(400, {"error": (proc.stderr or "failed").strip()[:200]})
            return
        self._json(200, {"ok": True})

    def _admin(self, method, path):
        """The signed team admin of this request, or None once the refusal is sent."""
        user = signed_user(self.headers, method, path, read_hmac_key(), int(time.time()))
        if not user:
            self._json(401, {"error": "no signed user: open the dashboard through the gateway"})
            return None
        if user not in team_admins():
            self._json(403, {"error": "not a team admin"})
            return None
        return user

    def _team_secret(self, user, name, body):
        """Store a new version of a secret the team's record names. The value goes to the ctl on stdin and
        never comes back, in the answer, a log or the audit row."""
        sec, value = body.get("secret"), body.get("value")
        if not (isinstance(sec, str) and re.fullmatch(rf"fxa-team-{name}--[a-z0-9]+(-[a-z0-9]+)*", sec)) or not isinstance(value, str) or not value:
            self._json(400, {"error": f"send {{\"secret\": \"fxa-team-{name}--...\", \"value\": \"...\"}}"})
            return
        try:
            proc = ctl_run(["profile", "secret-set", name, sec], timeout=60, env={"FXA_TEAM_ACTOR": user}, input=value)
        except Exception as exc:
            self._json(503, {"error": type(exc).__name__})
            return
        out = (proc.stdout if proc.returncode == 0 else proc.stderr or "failed").strip().replace(value, "<value>")[-500:]
        self._json(200 if proc.returncode == 0 else 400, {"ok": True, "out": out} if proc.returncode == 0 else {"error": out})

    def _team_ctl(self, user, args, record=None, read=False, cmd="profile"):
        """Run a profile (or routine) command as the admin, the record in a private temp file; 409 for a stale
        generation or version. A read answers with the command's JSON; a write answers ok and refreshes the teams list."""
        f = None
        try:
            if record is not None:
                fd, f = tempfile.mkstemp(suffix=".json")
                with os.fdopen(fd, "w") as out:
                    json.dump(record, out)
            proc = ctl_run([cmd, *[f if a is None else a for a in args]], timeout=120, env={"FXA_TEAM_ACTOR": user})
        except Exception as exc:
            self._json(503, {"error": type(exc).__name__})
            return
        finally:
            if f:
                os.unlink(f)
        if proc.returncode != 0:
            self._json(409 if proc.returncode == 2 else 400, {"error": (proc.stderr or proc.stdout or "failed").strip()[-2000:]})
        elif read:
            try:
                self._json(200, json.loads(proc.stdout or "null"))
            except ValueError:
                self._json(502, {"error": "the profile command did not answer JSON"})
        else:
            self._json(200, {"ok": True, "out": proc.stdout.strip()[-2000:]})
            if cmd == "profile" and TEAMS.claim():
                threading.Thread(target=TEAMS.refresh, args=(True,), daemon=True).start()

    def _team_test(self, user, name):
        """Start profile test in the background (it boots a runner for minutes); its log goes beside the record."""
        teams = Path(os.environ.get("FXA_TEAMS_DIR") or Path.home() / ".claude/state/teams")
        pidf, log = teams / f"{name}.test.pid", teams / f"{name}.test.log"
        try:
            os.kill(int(pidf.read_text()), 0)
            self._json(409, {"error": "a test of this team is already running"})
            return
        except (OSError, ValueError):
            pass
        if not (teams / f"{name}.json").exists():
            self._json(404, {"error": f"no team record {name}"})
            return
        with open(log, "w") as out:
            p = subprocess.Popen([str(CTL), "profile", "test", name], stdout=out, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                 start_new_session=True, env={**os.environ, "FXA_TEAM_ACTOR": user})
        pidf.write_text(str(p.pid))
        self._json(202, {"ok": True, "out": f"testing {name}: it boots one runner, a few minutes. Load the record again to see the result."})

    def _routine_write(self, path):
        """POST /api/teams/<name>/routines[/<id>[/pause|resume|delete]]: a signed admin's change, JSON only, 64 KB at most."""
        m = re.fullmatch(rf"/api/teams/({TEAM_NAME})/routines(?:/([0-9]{{1,9}})(?:/(pause|resume|delete|run|stop))?)?", path)
        user = self._admin("POST", path)
        if not user:
            return
        name, rid, verb = m.groups()
        if (self.headers.get("Content-Type") or "").split(";")[0].strip() != "application/json":
            self._json(415, {"error": "send JSON"})
            return
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            n = -1
        # A negative length would make read() wait for the end of the stream.
        if n < 0:
            self._json(400, {"error": "bad Content-Length"})
            return
        if n > 65536:
            self._json(413, {"error": "the routine is over 64 KB"})
            return
        try:
            body = json.loads(self.rfile.read(n) or b"{}")
        except (ValueError, json.JSONDecodeError):
            self._json(400, {"error": "bad JSON"})
            return
        if not isinstance(body, dict):
            self._json(400, {"error": "send a JSON object"})
            return
        rec, ver = body.get("routine"), str(body.get("version") or "")
        if verb:
            self._team_ctl(user, [{"run": "run-now"}.get(verb, verb), name, rid], cmd="routine")
        elif not isinstance(rec, dict):
            self._json(400, {"error": "send {\"routine\": {...}}"})
        elif not rid:
            self._team_ctl(user, ["set", name, None], rec, cmd="routine")
        elif not ver.isdigit():
            self._json(400, {"error": "send the version you edited"})
        else:
            self._team_ctl(user, ["set", name, None, "--id", rid, "--version", ver], rec, cmd="routine")

    def _team_write(self, path):
        """POST /api/teams[/validate|/<name>[/status|/delete]]: a signed admin's change, JSON only, 64 KB at most."""
        m = re.fullmatch(rf"/api/teams(?:/(validate)|/({TEAM_NAME})(?:/(status|delete|test|secret))?)?", path)
        if not m:
            self._json(404, {"error": "not found"})
            return
        user = self._admin("POST", path)
        if not user:
            return
        validate, name, verb = m.groups()
        if (self.headers.get("Content-Type") or "").split(";")[0].strip() != "application/json":
            self._json(415, {"error": "send JSON"})
            return
        n = int(self.headers.get("Content-Length") or 0)
        if n > 65536:
            self._json(413, {"error": "the record is over 64 KB"})
            return
        try:
            body = json.loads(self.rfile.read(n) or b"{}")
        except (ValueError, json.JSONDecodeError):
            self._json(400, {"error": "bad JSON"})
            return
        rec, gen = body.get("record"), str(body.get("generation") or "")
        if verb == "test":
            self._team_test(user, name)
        elif verb == "secret":
            self._team_secret(user, name, body)
        elif verb == "delete":
            self._team_ctl(user, ["delete", name])
        elif verb == "status":
            st = {"active": "enable", "disabled": "disable", "draft": "draft"}.get(body.get("status"))
            self._json(400, {"error": "status is active, disabled or draft"}) if not st else self._team_ctl(user, [st, name])
        elif not isinstance(rec, dict):
            self._json(400, {"error": "send {\"record\": {...}}"})
        elif validate:
            self._team_ctl(user, ["validate", None], rec)
        elif not name:
            self._team_ctl(user, ["create", None], rec)
        elif not gen.isdigit():
            self._json(400, {"error": "send the generation you edited"})
        else:
            self._team_ctl(user, ["set", name, None, "--generation", gen], rec)

    def do_POST(self):
        path = self.path.split("?")[0]
        if not self._allowed(True):
            return
        if path == "/api/lessons":
            self._lesson_decide()
            return
        if re.fullmatch(rf"/api/teams/{TEAM_NAME}/routines(/[0-9]{{1,9}}(/(pause|resume|delete|run|stop))?)?", path):
            self._routine_write(path)
            return
        if path.startswith("/api/teams"):
            self._team_write(path)
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
        # The watch page is open to anyone IAP admits, so a private repo's code never goes there.
        if team_private(found[2]):
            self._json(403, {"error": "this team has a private repo, so its sessions cannot be watched"})
            return
        # A gated team or a gated channel: only a dashboard user (signed by the gateway) may watch it.
        access, _ = read_access()
        if watch_narrow(found[2], thread.split(":", 1)[0], access, read_records(), read_gates(), found[3]):
            viewer = signed_user(self.headers, "GET", "/api/watch/events", read_hmac_key(), int(time.time()))
            if not viewer:
                self._json(403, {"error": "this session's team or channel is gated, so only dashboard users can watch it"})
                return
        if not WATCHERS.acquire(blocking=False):
            self._json(503, {"error": "too many watchers; try again soon"})
            return
        key, state = found[0], found[1]
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
        # Who the page is for: the signed user and whether they may change teams (the editor shows only then).
        if path == "/api/team-admin":
            user = signed_user(self.headers, "GET", path, read_hmac_key(), int(time.time()))
            self._json(200, {"user": user, "admin": bool(user and user in team_admins())})
            return
        # Each team's routine counts and failures for the Teams page: admins only (i168 D1). A store that
        # cannot be read is an error, never an empty summary that would read as "no routines".
        if path == "/api/routines/summary":
            if self._admin("GET", path):
                try:
                    con = fxadb.connect(readonly=True)
                    try:
                        self._json(200, fxadb.routine_summary(con, int(time.time())))
                    finally:
                        con.close()
                except Exception:  # noqa: BLE001  a fixed text: the error may name a path
                    self._json(503, {"error": "the routine store cannot be read"})
            return
        # Routines: admins only, for reading too (the design's D1).
        m = re.fullmatch(rf"/api/teams/({TEAM_NAME})/routines(?:/([0-9]{{1,9}})/history)?", path)
        if m or path == "/api/routine-templates":
            user = self._admin("GET", path)
            if user:
                args = ["templates"] if not m else ["history", m.group(1), m.group(2)] if m.group(2) else ["list", m.group(1)]
                self._team_ctl(user, args, read=True, cmd="routine")
            return
        # One team's full record and its audit: admins only, since a record names Slack users.
        m = re.fullmatch(rf"/api/teams/({TEAM_NAME})(/audit|/secrets)?", path)
        if m:
            user = self._admin("GET", path)
            if user:
                self._team_ctl(user, [{"/audit": "audit", "/secrets": "secrets"}.get(m.group(2) or "", "get"), m.group(1)], read=True)
            return
        if path in ("/", "/index.html"):
            page = (ROOT / "index.html").read_text()
            self._send(200, page, "text/html; charset=utf-8", csp_for(page))
        elif path == "/icon.png":
            self._send(200, (ROOT / "icon.png").read_bytes(), "image/png")
        elif path == "/api/snapshot":
            snap, age, err, busy = FULL.read()
            ag, ag_age, ag_err, ag_busy = AGENTS.read()
            if isinstance(ag, dict) and not self._team_admin(path):
                ag = dict(ag, sessions=[redact_session(s) if isinstance(s, dict) and team_private(s.get("profile") or "fxa") else s
                                        for s in ag.get("sessions") or []])
            # The stats feed's age and error, so a page tells live figures from old ones; /api/stats stays as it is.
            _, st_age, st_err, _ = STATS.read()
            self._json(200, {
                "stats_age_seconds": st_age, "stats_error": st_err, "stats_interval": STATS.interval,
                "snapshot": snap, "age_seconds": age, "error": err,
                "agents": ag, "agents_age_seconds": ag_age, "agents_error": ag_err,
                "refreshing": busy or ag_busy,
                "interval": FULL.interval, "agents_interval": AGENTS.interval,
            })
        elif path == "/api/tail":
            key = arg("key")
            # agent_tail lowercases the key, so the private check must see the same session: AGENT-123456 is agent-123456.
            if key.lower().startswith("agent-"):
                key = key.lower()
            if not re.fullmatch(r"[A-Za-z][A-Za-z0-9]*-\d+|agent-[a-z0-9]{4,12}", key):
                self._json(400, {"error": "bad key"})
            elif key.startswith("agent-") and session_private(key) and not self._team_admin(path):
                self._json(403, {"error": "a private team's session: team admins only"})
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
            if session_private(key) and not self._team_admin(path):
                self._json(403, {"error": "a private team's session: team admins only"})
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
            if body.get("rows") and not self._team_admin(path):
                body["rows"] = [redact_session(r) if not r.get("deleted") and team_private(r.get("profile") or "fxa") else r for r in body["rows"]]
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
        elif path == "/api/runs/recent":
            lim, days = arg("limit"), arg("days")
            rows = (STATS.read()[0] or {}).get("rows")
            # A private team's runs name its tickets: only a signed team admin sees them, as with lessons.
            admin = signed_user(self.headers, "GET", path, read_hmac_key(), int(time.time())) in team_admins()
            runs = recent_runs(rows, FULL.read()[0], int(time.time()), min(int(lim), 100) if lim.isdigit() and int(lim) else 20,
                               min(int(days), 90) if days.isdigit() and int(days) else 7, os.path.dirname(ERRORS_FILE), str(SESSION_DIR),
                               lambda t: not admin and team_private(t), admin)
            self._json(200, {"runs": runs, "error": None if rows is not None else "stats unavailable"})
        elif path == "/api/stats":
            data = STATS.read()[0]
            self._json(200, data if data is not None else {"error": "stats unavailable"})
        elif path == "/api/teams":
            data, age, err, busy = TEAMS.read()
            access, access_err = read_access()
            records = read_records()
            teams = []
            if data is not None:  # the diff needs the list; before it, every dir would look broken
                listed = {t.get("profile") for t in data}
                now = int(time.time())
                teams = [dict(t, access=team_access(t.get("profile"), access, records), test=team_test(t.get("profile"), now),
                              **dict(zip(("budget", "budget_error"), team_budget(t.get("profile"), now)))) for t in data]
                teams += [{"profile": d, "load_error": True}
                          for d in sorted(p.parent.name for p in PROFILES_DIR.glob("*/profile.conf")) if d not in listed]
            per, top = team_issues(teams, access if data is not None else None, records)
            self._json(200, {"teams": [dict(t, issues=i) for t, i in zip(teams, per)], "issues": top,
                             # The file name only: the path names the operator's home directory.
                             "access_source": access and {"file": os.path.basename(access["path"]), "mtime": access["mtime"]},
                             "access_error": access_err, "age_seconds": age, "error": err,
                             "refreshing": busy, "interval": TEAMS.interval})
        elif path == "/api/lessons":
            try:
                proc = ctl_run(["lessons", "--json"], timeout=15)
                rows = json.loads(proc.stdout) if proc.returncode == 0 and proc.stdout.strip() else []
            except Exception:
                rows = []
            # A private team's lessons can quote its code: only a signed team admin sees them (i358).
            admin = signed_user(self.headers, "GET", path, read_hmac_key(), int(time.time())) in team_admins()
            self._json(200, [r for r in rows if isinstance(r, dict) and (admin or not team_private(r.get("team") or "fxa"))])
        elif path == "/api/errors":
            self._send(200, cached_ctl(ERRORS, ["errors", "--json"], 20, 20) or "[]", "application/json")
        elif path == "/api/history":
            key = arg("key")
            if not re.fullmatch(r"agent-[a-z0-9]{4,12}", key):
                self._json(400, {"error": "bad key"})
                return
            if session_private(key) and not self._team_admin(path):
                self._json(403, {"error": "a private team's session: team admins only"})
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
