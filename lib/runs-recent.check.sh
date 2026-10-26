#!/usr/bin/env bash
# Offline check of /api/runs/recent: order, outcomes, PR links, a secured ticket, a private team's runs.
#   bash lib/runs-recent.check.sh
set -u
T=$(mktemp -d "${TMPDIR:-/tmp}/runs-recent.XXXXXX"); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/state" "$T/sess"; : > "$T/state/FXA-3.secured-noted"; printf 'Why does sync fail?\nmore\n' > "$T/sess/agent-aaaa11.prompt.md"
printf 'Review the private commits\n' > "$T/sess/agent-rout01.prompt.md"; echo '{"key": "agent-rout01", "routine_run": 7}' > "$T/sess/agent-rout01.json"
printf 'Host frame for PR 90001\n' > "$T/sess/agent-fix001.prompt.md"
echo '{"key": "agent-fix001", "routine_run": 9, "fix_pr": 90001, "fix_trigger": "label", "fix_actor": "octo-example", "pr_url": "https://github.com/mozilla/fxa/pull/90001"}' > "$T/sess/agent-fix001.json"
python3 - "$(dirname "$0")/../dashboard" "$T" <<'PY'
import json, sys, threading, time, urllib.request
sys.path.insert(0, sys.argv[1]); import server
from http.server import ThreadingHTTPServer
t = sys.argv[2]
server.ERRORS_FILE, server.SESSION_DIR = t + "/state/errors.jsonl", t + "/sess"
server.team_private = lambda team: team == "secret-team"
now = time.time(); iso = lambda ago: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now - ago))
rows = [
    {"at": iso(600), "src": "pipeline", "key": "FXA-1", "end": int(now - 100), "kind": "fix", "usd": 3.5, "min": 20, "pr": True, "profile": "fxa"},
    {"at": iso(500), "src": "pipeline", "key": "FXA-2", "kind": "fix", "usd": 1.0, "min": 9, "pr": False, "profile": "fxa"},
    {"at": iso(400), "src": "pipeline", "key": "FXA-3", "kind": "fix", "usd": 2.0, "min": 12, "pr": True, "profile": "fxa"},
    {"at": iso(300), "src": "slack", "key": "agent-aaaa11", "end": int(now - 200), "backend": "firecracker", "boot_s": 38, "peak": {"mem_mb": 6144}, "stop": "idle", "kind": "session", "usd": 0.4, "min": 5, "pr": False, "prn": None, "profile": "fxa"},
    {"at": iso(200), "src": "pipeline", "key": "PRIV-1", "end": int(now - 50), "kind": "fix", "usd": 1.0, "min": 5, "pr": True, "profile": "secret-team"},
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
# A routine named in its record is titled by that name: every run's prompt starts with the same schedule preamble.
json.dump({"key": "agent-rout01", "routine_run": 7, "routine_name": "Code review"}, open(t + "/sess/agent-rout01.json", "w"))
check("a named routine run is titled by its routine, not its prompt's first line", "Code review run", server.recent_runs(rows, snap, int(now), 20, 7, t + "/state", t + "/sess", lambda team: False, True)[0]["title"])
json.dump({"key": "agent-rout01", "routine_run": 7}, open(t + "/sess/agent-rout01.json", "w"))
check("a pass is left out: the system card shows passes", False, "pass" in by)
check("limit", 2, len(get("/api/runs/recent?limit=2")["runs"]))
check("days=30 takes the older run", "FXA-9", get("/api/runs/recent?days=30&limit=100")["runs"][-1]["key"])
check("an admin sees the private team's run", True, any(r["key"] == "PRIV-1" for r in server.recent_runs(rows, snap, int(now), 20, 7, t + "/state", t + "/sess", lambda team: False)))
e = get("/api/runs/recent?ended=1&limit=100")["runs"]
check("ended=1: ended pipeline and Slack runs, newest end first, the private team's run still hidden", ["FXA-1", "agent-aaaa11"], [r["key"] for r in e])
check("ended=1: the Slack run's where, boot, memory, stop and end", ("firecracker", 38, 6144, "idle", int(now - 200), False), tuple(e[1][k] for k in ("where", "boot_s", "mem_mb", "stop", "end", "routine")))
check("a routine run in ended mode keeps its gate: no prompt, no key, routine true", ("Scheduled run", "", True), (lambda x: (x["title"], x["key"], x["routine"]))(server.recent_runs(rows + [dict(next(r for r in rows if r["key"] == "agent-rout01"), end=int(now - 10))], snap, int(now), 20, 7, t + "/state", t + "/sess", lambda team: False, False, True)[0]))
check("a run with no end: end from at", int(now - 500), by["FXA-2"]["end"])
check("a routine run for a non-admin sends no team, cost, minutes or stop reason", ("", None, None, None), (lambda x: (x["team"], x["usd"], x["min"], x["stop"]))(b["runs"][0]))
many = rows + [{"at": iso(10 + i), "src": "slack", "key": f"agent-zz{i:04d}", "kind": "session", "usd": 0.1, "min": 1, "end": int(now - 10 - i), "profile": "fxa"} for i in range(120)]
s = server.recent_runs(many, snap, int(now), 100, 7, t + "/state", t + "/sess", lambda team: False, True, True, "pipeline")
check("src=pipeline filters before the limit: 120 newer Slack runs do not push the pipeline runs out", ["PRIV-1", "FXA-1"], [r["key"] for r in s])
check("src=routine keeps only routine runs", [True], [r["routine"] for r in server.recent_runs(rows, snap, int(now), 20, 7, t + "/state", t + "/sess", lambda team: False, True, False, "routine")])
check("the route passes src", ["FXA-1"], [r["key"] for r in get("/api/runs/recent?ended=1&src=pipeline&limit=100")["runs"]])
fx = [{"at": iso(120), "src": "depfix", "key": "agent-fix001", "end": int(now - 30), "kind": "session", "usd": 0.7, "min": 6, "pr": False, "prn": None, "stop": "done", "profile": "fxa"}]
rr = lambda admin, ended=False, src=None: server.recent_runs(fx, snap, int(now), 20, 7, t + "/state", t + "/sess", lambda team: False, admin, ended, src)
check("a dependency fix for a team admin: its PR, trigger and actor", ("Dependency fix: #90001 (label by octo-example)", 90001, "label", "octo-example", "https://github.com/mozilla/fxa/pull/90001", "agent-fix001", 0.7),
      (lambda x: (x["title"], x["pr_number"], x.get("fix_trigger"), x.get("fix_actor"), x["pr_url"], x["key"], x["usd"]))(rr(True)[0]))
check("a dependency fix for a non-admin: only that it ran, with no PR, team, cost or fix fields", ("Dependency fix", "", None, "", None, None, "depfix", True),
      (lambda x: (x["title"], x["key"], x["pr_number"], x["team"], x["usd"], x.get("fix_pr"), x["src"], x["routine"]))(rr(False)[0]))
check("a dependency fix is in Recently completed and on the routine filter", (1, 1), (len(rr(True, True)), len(rr(True, False, "routine"))))
server.STATS.data = None
check("no stats feed: empty with an error", ([], "stats unavailable"), (lambda x: (x["runs"], x["error"]))(get("/api/runs/recent")))
sys.exit(fail)
PY
