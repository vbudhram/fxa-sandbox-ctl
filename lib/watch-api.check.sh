#!/usr/bin/env bash
# Offline check that the dashboard's /api/watch finds a thread's newest session and tails it only while it runs.
#   bash lib/watch-api.check.sh
set -u
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
T="C0AB12CD3:1791135361.015169"
echo '{"sessions":"agent-aaaaaa agent-bbbbbb"}' > "$tmp/thread-C0AB12CD3-1791135361.015169.json"
echo '{"state":"active"}' > "$tmp/agent-bbbbbb.json"
echo '{"thread":"C0AB12CD3:1790000000.000001","sessions":"agent-cccccc"}' > "$tmp/thread-C0AB12CD3-1790000000.000001.json"
echo '{"state":"paused"}' > "$tmp/agent-cccccc.json"
FXA_SESSION_DIR="$tmp" python3 - "$(dirname "$0")/../dashboard" <<'PY'
import json, sys, threading, urllib.error, urllib.request
sys.path.insert(0, sys.argv[1]); import server
from http.server import ThreadingHTTPServer
server.agent_tail = lambda key: [f"tail of {key}"]
srv = ThreadingHTTPServer(("127.0.0.1", 0), server.Handler); threading.Thread(target=srv.serve_forever, daemon=True).start()
fail = 0
def get(q):
    req = urllib.request.Request(f"http://127.0.0.1:{srv.server_port}/api/watch?thread={q}", headers={"Host": "localhost"})
    try:
        with urllib.request.urlopen(req) as r: return r.status, json.load(r)
    except urllib.error.HTTPError as e: return e.code, json.load(e)
def check(name, want, got):
    global fail
    ok = want == got; fail |= not ok
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f": want {want!r} got {got!r}"))
check("the newest session, tailed while it runs", (200, {"key": "agent-bbbbbb", "state": "active", "lines": ["tail of agent-bbbbbb"]}), get("C0AB12CD3:1791135361.015169"))
check("a paused session: its state, no tail", (200, {"key": "agent-cccccc", "state": "paused", "lines": []}), get("C0AB12CD3:1790000000.000001"))
check("an unknown thread: 404", 404, get("C0AB12CD3:1700000000.000001")[0])
check("a bad thread: 400", 400, get("..%2Fx")[0])
srv.shutdown(); sys.exit(fail)
PY
