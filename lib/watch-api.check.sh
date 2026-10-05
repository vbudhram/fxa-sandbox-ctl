#!/usr/bin/env bash
# Offline check that /api/watch/events finds a thread's newest session and streams its view only while it runs.
#   bash lib/watch-api.check.sh
set -u
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
echo '{"sessions":"agent-aaaaaa agent-bbbbbb"}' > "$tmp/thread-C0AB12CD3-1791135361.015169.json"
echo '{"state":"active"}' > "$tmp/agent-bbbbbb.json"
echo '{"sessions":"agent-cccccc"}' > "$tmp/thread-C0AB12CD3-1790000000.000001.json"
echo '{"state":"paused"}' > "$tmp/agent-cccccc.json"
# The ctl's view: two events, as `fxa-sandbox-ctl view <key>` prints them.
printf '#!/bin/sh\necho "{\\"t\\":\\"text\\",\\"text\\":\\"$4\\"}"\necho "{\\"t\\":\\"turn_end\\"}"\n' > "$tmp/ctl"; chmod +x "$tmp/ctl"
FXA_SESSION_DIR="$tmp" python3 - "$(dirname "$0")/../dashboard" "$tmp/ctl" <<'PY'
import sys, threading, urllib.error, urllib.request
sys.path.insert(0, sys.argv[1]); import server
from http.server import ThreadingHTTPServer
server.CTL, server.PIPELINE = sys.argv[2], "test"
srv = ThreadingHTTPServer(("127.0.0.1", 0), server.Handler); threading.Thread(target=srv.serve_forever, daemon=True).start()
fail = 0
def get(q):
    req = urllib.request.Request(f"http://127.0.0.1:{srv.server_port}/api/watch/events?thread={q}", headers={"Host": "localhost"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r: return r.status, r.headers.get("Content-Type"), r.read().decode()
    except urllib.error.HTTPError as e: return e.code, None, ""
def check(name, want, got):
    global fail
    ok = want == got; fail |= not ok
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f": want {want!r} got {got!r}"))
st, ct, body = get("C0AB12CD3:1791135361.015169")
check("a running session streams", (200, "text/event-stream"), (st, ct))
check("the newest session, then its view, then the end", 'event: session\ndata: {"key": "agent-bbbbbb", "state": "active"}\n\n'
      'data: {"t":"text","text":"agent-bbbbbb"}\n\ndata: {"t":"turn_end"}\n\nevent: end\ndata: {}\n\n', body)
check("a paused session: its state and the end, no view", 'event: session\ndata: {"key": "agent-cccccc", "state": "paused"}\n\nevent: end\ndata: {}\n\n',
      get("C0AB12CD3:1790000000.000001")[2])
check("an unknown thread: 404", 404, get("C0AB12CD3:1700000000.000001")[0])
check("a bad thread: 400", 400, get("..%2Fx")[0])
srv.shutdown(); sys.exit(fail)
PY
