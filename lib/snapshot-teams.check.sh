#!/usr/bin/env bash
# Offline check of the multi-team snapshot: which teams get a feed, and what each viewer sees of each team.
#   bash lib/snapshot-teams.check.sh
set -u
T=$(mktemp -d "${TMPDIR:-/tmp}/snap-teams.XXXXXX"); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/state/pub" "$T/state/fxa-ai-fixme"; : > "$T/state/pub/PUB-2.secured-noted"
python3 - "$(dirname "$0")/../dashboard" "$T" <<'PY'
import json, sys, threading, time, urllib.request
sys.path.insert(0, sys.argv[1]); import server
from http.server import ThreadingHTTPServer
t = sys.argv[2]
fail = 0
def check(name, want, got):
    global fail
    ok = want == got; fail |= not ok
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f": want {want!r} got {got!r}"))
recs = {"fxa": {"status": "active", "queue": True, "jira": "FXA"}, "pub": {"status": "active", "queue": True, "jira": "PUB"},
        "priv": {"status": "active", "queue": True, "jira": "PRV"}, "sec": {"status": "active", "queue": True, "jira": "FXA", "secret": True},
        "noq": {"status": "active", "queue": False, "jira": ""}, "off": {"status": "draft", "queue": True, "jira": "OFF"}}
check("pipeline teams: active, with a queue and a Jira project, fxa left to its own feed", ["priv", "pub", "sec"], server.pipeline_teams(recs))
snap = lambda p: {"team": {"profile": p, "name": p.upper(), "repo": f"o/{p}"}, "queue": {"ready": [{"key": f"{p}-1", "summary": "s"}], "skipped": []},
                  "inflight": [{"key": f"{p}-2", "summary": "secret topic"}], "review": [], "blocked": [], "open_prs": [], "merged_prs": [{"key": f"{p}-3", "title": "t"}]}
server.STATE_ROOT, server.read_records = t + "/state", lambda: recs
server.team_private = lambda team: team == "priv"
server.TEAM_FEEDS = {k: server.Feed(k, [], 300, 300) for k in ("pub", "priv", "sec")}
for k, f in server.TEAM_FEEDS.items():
    f.data, f.fetched_at = snap(k.upper()), time.time()
server.TEAM_FEEDS["pub"].data["inflight"] = [{"key": "PUB-2", "summary": "now secured"}, {"key": "PUB-4", "summary": "open"}]
server.FULL = server.Feed("snapshot", [], 60, 30); server.AGENTS = server.Feed("agents", [], 15, 30); server.STATS = server.Feed("stats", [], 60, 30)
srv = ThreadingHTTPServer(("127.0.0.1", 0), server.Handler); threading.Thread(target=srv.serve_forever, daemon=True).start()
def get(admin):
    server.Handler._team_admin = lambda self, path: admin
    req = urllib.request.Request(f"http://127.0.0.1:{srv.server_port}/api/snapshot", headers={"Host": "localhost"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read().decode())["teams"]
v, a = get(False), get(True)
check("a viewer sees the public and private teams, never the secret team", ["priv", "pub"], sorted(v))
check("a viewer gets a private team as counts only: no summaries, titles or repo", (True, {"ready": 1, "skipped": 0, "inflight": 1, "review": 0, "blocked": 0, "open_prs": 0, "merged_prs": 1}, False),
      (v["priv"]["snapshot"]["redacted"], v["priv"]["snapshot"]["counts"], "secret topic" in json.dumps(v["priv"])))
check("a viewer does not see a public team's ticket that its own state folder marks secured", ["PUB-4"], [i["key"] for i in v["pub"]["snapshot"]["inflight"]])
check("a team admin sees every team in full, the secret team included", (["priv", "pub", "sec"], "secret topic", 2),
      (sorted(a), a["sec"]["snapshot"]["inflight"][0]["summary"], len(a["pub"]["snapshot"]["inflight"])))
server.TEAM_FEEDS["sec"].data = None
check("a secret team that has not loaded yet is still left out for a viewer", False, "sec" in get(False))
server.TEAM_FEEDS["pub"].data, server.TEAM_FEEDS["pub"].error = None, "Jira did not answer"
check("a team whose read failed says so, with no snapshot (the page shows unknown)", (None, "Jira did not answer"), (get(False)["pub"]["snapshot"], get(False)["pub"]["error"]))
sys.exit(fail)
PY
