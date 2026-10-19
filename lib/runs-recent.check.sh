#!/usr/bin/env bash
# Offline check of /api/runs/recent: order, outcomes, PR links, a secured ticket, a private team's runs.
#   bash lib/runs-recent.check.sh
set -u
T=$(mktemp -d "${TMPDIR:-/tmp}/runs-recent.XXXXXX"); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/state" "$T/sess"; : > "$T/state/FXA-3.secured-noted"; printf 'Why does sync fail?\nmore\n' > "$T/sess/agent-aaaa11.prompt.md"
printf 'Review the private commits\n' > "$T/sess/agent-rout01.prompt.md"; echo '{"key": "agent-rout01", "routine_run": 7}' > "$T/sess/agent-rout01.json"
python3 - "$(dirname "$0")/../dashboard" "$T" <<'PY'
import json, sys, threading, time, urllib.request
sys.path.insert(0, sys.argv[1]); import server
from http.server import ThreadingHTTPServer
t = sys.argv[2]
server.ERRORS_FILE, server.SESSION_DIR = t + "/state/errors.jsonl", t + "/sess"
server.team_private = lambda team: team == "secret-team"
now = time.time(); iso = lambda ago: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now - ago))
rows = [
    {"at": iso(600), "src": "pipeline", "key": "FXA-1", "kind": "fix", "usd": 3.5, "min": 20, "pr": True, "profile": "fxa"},
    {"at": iso(500), "src": "pipeline", "key": "FXA-2", "kind": "fix", "usd": 1.0, "min": 9, "pr": False, "profile": "fxa"},
    {"at": iso(400), "src": "pipeline", "key": "FXA-3", "kind": "fix", "usd": 2.0, "min": 12, "pr": True, "profile": "fxa"},
    {"at": iso(300), "src": "slack", "key": "agent-aaaa11", "kind": "session", "usd": 0.4, "min": 5, "pr": False, "prn": None, "profile": "fxa"},
    {"at": iso(200), "src": "pipeline", "key": "PRIV-1", "kind": "fix", "usd": 1.0, "min": 5, "pr": True, "profile": "secret-team"},
    {"at": iso(150), "src": "slack", "key": "agent-rout01", "kind": "session", "usd": 0.3, "min": 4, "pr": False, "prn": None, "profile": "fxa"},
    {"at": iso(100), "src": "pass", "key": "pass", "kind": "pass", "usd": 0.5, "min": 2, "pr": False, "profile": "fxa"},
    {"at": iso(9 * 86400), "src": "pipeline", "key": "FXA-9", "kind": "fix", "usd": 1, "min": 1, "pr": False, "profile": "fxa"},
]
snap = {"repo": "mozilla/fxa", "merged_prs": [{"key": "FXA-1", "number": 11, "title": "fix(auth): one"}, {"key": "FXA-3", "number": 13, "title": "the secret fix"}],
        "queue": {"skipped": [{"key": "FXA-2", "summary": "Two"}]}}
server.FULL = server.Feed("snapshot", [], 60, 30); server.STATS = server.Feed("stats", [], 60, 30); server.AGENTS = server.Feed("agents", [], 15, 30)
server.FULL.data, server.FULL.fetched_at = snap, now
server.STATS.data, server.STATS.fetched_at = {"rows": rows}, now
srv = ThreadingHTTPServer(("127.0.0.1", 0), server.Handler); threading.Thread(target=srv.serve_forever, daemon=True).start()
fail = 0
def get(p):
    req = urllib.request.Request(f"http://127.0.0.1:{srv.server_port}{p}", headers={"Host": "localhost"})
    with urllib.request.urlopen(req, timeout=10) as r: return json.loads(r.read().decode())
def check(name, want, got):
    global fail
    ok = want == got; fail |= not ok
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f": want {want!r} got {got!r}"))
try:
    b = get("/api/runs/recent")
except Exception as e:
    print(f"FAIL /api/runs/recent: {e}"); sys.exit(1)
by = {r["key"]: r for r in b["runs"]}
check("newest first, 7 days, a non-admin does not see the private team's run", ["", "agent-aaaa11", "FXA-3", "FXA-2", "FXA-1"], [r["key"] for r in b["runs"]])
check("a pipeline run with a merged PR", ("pr", 11, "merged", "https://github.com/mozilla/fxa/pull/11", "fix(auth): one"),
      tuple(by["FXA-1"][k] for k in ("outcome", "pr_number", "pr_state", "pr_url", "title")))
check("a pipeline run with no PR, titled from the queue", ("no_pr", None, "Two"), tuple(by["FXA-2"][k] for k in ("outcome", "pr_url", "title")))
check("a secured ticket shows no title and no PR", ("Secured ticket", None, None), tuple(by["FXA-3"][k] for k in ("title", "pr_url", "pr_number")))
check("a Slack session: the request's first line, answered", ("Why does sync fail?", "answered", "fxa"), tuple(by["agent-aaaa11"][k] for k in ("title", "outcome", "team")))
check("a routine's session: a non-admin sees no prompt and no key", ("Scheduled run", ""), (b["runs"][0]["title"], b["runs"][0]["key"]))
check("a team admin sees the routine's prompt", "Review the private commits", server.recent_runs(rows, snap, int(now), 20, 7, t + "/state", t + "/sess", lambda team: False, True)[0]["title"])
check("a pass is left out: the system card shows passes", False, "pass" in by)
check("limit", 2, len(get("/api/runs/recent?limit=2")["runs"]))
check("days=30 takes the older run", "FXA-9", get("/api/runs/recent?days=30&limit=100")["runs"][-1]["key"])
check("an admin sees the private team's run", True, any(r["key"] == "PRIV-1" for r in server.recent_runs(rows, snap, int(now), 20, 7, t + "/state", t + "/sess", lambda team: False)))
server.STATS.data = None
check("no stats feed: empty with an error", ([], "stats unavailable"), (lambda x: (x["runs"], x["error"]))(get("/api/runs/recent")))
sys.exit(fail)
PY
