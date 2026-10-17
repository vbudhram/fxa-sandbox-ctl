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
# profile show: the team "secret" has a private repo, the others do not.
printf '#!/bin/sh\nif [ "$3" = profile ]; then [ "$2" = secret ] && echo "{\\"private\\":true}" || echo "{\\"private\\":false}"; exit 0; fi\necho "{\\"t\\":\\"text\\",\\"text\\":\\"$4\\"}"\necho "{\\"t\\":\\"turn_end\\"}"\n' > "$tmp/ctl"; chmod +x "$tmp/ctl"
echo '{"sessions":"agent-dddddd"}' > "$tmp/thread-C0AB12CD3-1790000000.000002.json"
echo '{"state":"active","profile":"secret"}' > "$tmp/agent-dddddd.json"
# A gated team (not open), and a channel in CHANNEL_GATES: only a viewer the gateway signs may watch.
echo '{"sessions":"agent-eeeeee"}' > "$tmp/thread-C0AB12CD3-1790000000.000003.json"
echo '{"state":"paused","profile":"closed"}' > "$tmp/agent-eeeeee.json"
echo '{"sessions":"agent-ffffff"}' > "$tmp/thread-CGATED0001-1790000000.000004.json"
echo '{"state":"paused"}' > "$tmp/agent-ffffff.json"
printf 'PROFILE_OPEN=team-a\nCHANNEL_GATES=CGATED0001:CPRIV00001\n' > "$tmp/bot.env"
printf 'k3y' > "$tmp/hmac"
FXA_SESSION_DIR="$tmp" FXA_BOT_ENV="$tmp/bot.env" FXA_TEAMS_DIR="$tmp/none" FXA_DASHBOARD_HMAC_FILE="$tmp/hmac" python3 - "$(dirname "$0")/../dashboard" "$tmp/ctl" <<'PY'
import hashlib, hmac, sys, threading, time, urllib.error, urllib.request
sys.path.insert(0, sys.argv[1]); import server
from http.server import ThreadingHTTPServer
server.CTL, server.PIPELINE = sys.argv[2], "test"
srv = ThreadingHTTPServer(("127.0.0.1", 0), server.Handler); threading.Thread(target=srv.serve_forever, daemon=True).start()
fail = 0
def get(q, viewer=None, key=b"k3y"):
    h = {"Host": "localhost"}
    if viewer:
        ts = str(int(time.time()))
        h.update({"X-Fxa-User": viewer, "X-Fxa-Time": ts, "X-Fxa-Sig": hmac.new(key, f"{viewer}|{ts}|GET|/api/watch/events".encode(), hashlib.sha256).hexdigest()})
    req = urllib.request.Request(f"http://127.0.0.1:{srv.server_port}/api/watch/events?thread={q}", headers=h)
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
check("a team with a private repo: 403, and no view", 403, get("C0AB12CD3:1790000000.000002")[0])
check("a gated team, no signed viewer: 403", 403, get("C0AB12CD3:1790000000.000003")[0])
check("a gated team, a signed dashboard user: watched", 200, get("C0AB12CD3:1790000000.000003", "user@example.com")[0])
check("a gated channel, no signed viewer: 403", 403, get("CGATED0001:1790000000.000004")[0])
check("a gated channel, a signature with another key: 403", 403, get("CGATED0001:1790000000.000004", "user@example.com", b"other")[0])
check("a gated channel, a signed dashboard user: watched", 200, get("CGATED0001:1790000000.000004", "user@example.com")[0])
check("an unknown thread: 404", 404, get("C0AB12CD3:1700000000.000001")[0])
check("a bad thread: 400", 400, get("..%2Fx")[0])
srv.shutdown(); sys.exit(fail)
PY
