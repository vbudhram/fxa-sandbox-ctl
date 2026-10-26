#!/usr/bin/env bash
# Render a dashboard view with live data and this tree's dashboard code, on the laptop, with no dev bot.
# The live feeds come from vm.sh api; this tree's dashboard/server.py answers the API from them, so a
# new or changed route is live-shaped before it ships. A change to the feeds themselves (lib/snapshot.sh)
# still needs vm.sh dev.
#   bash skills/fxa-ctl-dev/live-render.sh '#runners' [--admin] [--query 'ended=1&limit=100'] [page.sh options...]
# --query is the query string for /api/runs/recent (the fixture holds one answer per path).
set -eu
here="$(cd "$(dirname "$0")" && pwd)"; root="$(cd "$here/../.." && pwd)"
route="${1:?usage: live-render.sh <#route> [--admin] [--query q] [page.sh options]}"; shift
admin=false query="limit=4&days=30"
while [ $# -gt 0 ]; do case "$1" in --admin) admin=true; shift ;; --query) query="$2"; shift 2 ;; *) break ;; esac; done
t="$(mktemp -d "${TMPDIR:-/tmp}/live-render.XXXXXX")"; trap 'rm -rf "$t"' EXIT
for a in snapshot stats teams errors; do bash "$root/skills/fxa-manager/vm.sh" api "$a" > "$t/$a.json"; done
python3 - "$root/dashboard" "$t" "$admin" "$query" > "$t/fx.json" <<'PY'
import json, sys, threading, time, urllib.request
sys.path.insert(0, sys.argv[1]); import server
from http.server import ThreadingHTTPServer
t, admin, query = sys.argv[2], sys.argv[3] == "true", sys.argv[4]
live = {a: json.load(open(f"{t}/{a}.json")) for a in ("snapshot", "stats", "teams")}
now = time.time()
for name, data in (("FULL", live["snapshot"].get("snapshot")), ("AGENTS", live["snapshot"].get("agents")), ("STATS", live["stats"])):
    f = getattr(server, name, None) or server.Feed(name.lower(), [], 60, 30); setattr(server, name, f); f.data, f.fetched_at = data, now
if admin:
    server.team_admins = lambda: {None}   # an unsigned local request reads as a team admin
srv = ThreadingHTTPServer(("127.0.0.1", 0), server.Handler); threading.Thread(target=srv.serve_forever, daemon=True).start()
def get(p):
    req = urllib.request.Request(f"http://127.0.0.1:{srv.server_port}{p}", headers={"Host": "localhost"})
    with urllib.request.urlopen(req, timeout=30) as r: return json.loads(r.read().decode())
print(json.dumps({"/api/snapshot": get("/api/snapshot"), "/api/stats": get("/api/stats"), "/api/overview": get("/api/overview"), "/api/teams": live["teams"],
                  "/api/runs/recent": get("/api/runs/recent?" + query), "/api/team-admin": {"admin": admin},
                  "/api/errors": json.load(open(f"{t}/errors.json"))}))
PY
bash "$here/page.sh" "$route" --fixture "$t/fx.json" "$@"
