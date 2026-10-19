#!/usr/bin/env bash
# Offline check that /api/snapshot says how old the stats feed is, and /api/stats keeps its shape.
#   bash lib/snapshot-api.check.sh
set -u
python3 - "$(dirname "$0")/../dashboard" <<'PY'
import json, sys, threading, time, urllib.request
sys.path.insert(0, sys.argv[1]); import server
from http.server import ThreadingHTTPServer
server.FULL = server.Feed("snapshot", [], 60, 30); server.AGENTS = server.Feed("agents", [], 15, 30)
server.STATS = server.Feed("stats", [], 60, 30)
server.STATS.data, server.STATS.fetched_at, server.STATS.error = {"llm": {}}, time.time() - 400, "stats failed: timeout"
srv = ThreadingHTTPServer(("127.0.0.1", 0), server.Handler); threading.Thread(target=srv.serve_forever, daemon=True).start()
fail = 0
def get(p):
    req = urllib.request.Request(f"http://127.0.0.1:{srv.server_port}{p}", headers={"Host": "localhost"})
    with urllib.request.urlopen(req, timeout=10) as r: return json.loads(r.read().decode())
def check(name, want, got):
    global fail
    ok = want == got; fail |= not ok
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f": want {want!r} got {got!r}"))
s = get("/api/snapshot")
check("snapshot: the stats feed's age, error and interval", (True, "stats failed: timeout", 60),
      (400 <= (s.get("stats_age_seconds") or 0) <= 402, s.get("stats_error"), s.get("stats_interval")))
check("/api/stats has no new key", {"llm": {}}, get("/api/stats"))
server.STATS.data = server.STATS.fetched_at = server.STATS.error = None
check("snapshot: a stats feed never read gives null age", None, get("/api/snapshot").get("stats_age_seconds"))
sys.exit(fail)
PY
