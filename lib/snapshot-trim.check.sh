#!/usr/bin/env bash
# Offline check that GET /api/snapshot leaves out the session fields the page never reads, and keeps the rest.
#   bash lib/snapshot-trim.check.sh
set -u
python3 - "$(dirname "$0")/../dashboard" <<'PY'
import json, sys, threading, time, urllib.request
sys.path.insert(0, sys.argv[1]); import server
from http.server import ThreadingHTTPServer
fail = 0
def check(name, want, got):
    global fail
    print(("ok   " if want == got else "FAIL ") + name + ("" if want == got else f": want [{want}] got [{got}]")); fail |= want != got
for name in ("FULL", "AGENTS", "STATS"):
    f = server.Feed(name.lower(), [], 60, 30); f.data, f.fetched_at = {}, time.time(); setattr(server, name, f)
server.AGENTS.data = {"sessions": [{"key": "agent-a1", "state": "stopped", "profile": "fxa", "request": "fix it", "owner_image": "x" * 50, "claude_session_id": "c1", "cap_usd": 5}]}
server.team_admins = lambda: {None}
srv = ThreadingHTTPServer(("127.0.0.1", 0), server.Handler); threading.Thread(target=srv.serve_forever, daemon=True).start()
with urllib.request.urlopen(urllib.request.Request(f"http://127.0.0.1:{srv.server_port}/api/snapshot", headers={"Host": "localhost"}), timeout=10) as r:
    s = json.loads(r.read())["agents"]["sessions"][0]
check("the snapshot's sessions keep what the page reads and drop what it never does", (["key", "profile", "request", "state"], "fix it"), (sorted(s), s.get("request")))
check("the stored session is not changed", True, "owner_image" in server.AGENTS.data["sessions"][0])
sys.exit(fail)
PY
