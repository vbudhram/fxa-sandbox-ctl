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
# An FxA security-review routine session in an open channel: narrowed by its own record (D9).
echo '{"sessions":"agent-nrrw01"}' > "$tmp/thread-C0AB12CD3-1790000000.000007.json"
echo '{"state":"paused","watch_narrow":"1"}' > "$tmp/agent-nrrw01.json"
echo '{"sessions":"agent-ffffff"}' > "$tmp/thread-CGATED0001-1790000000.000004.json"
echo '{"state":"paused"}' > "$tmp/agent-ffffff.json"
echo '{"sessions":"agent-hhhhhh"}' > "$tmp/thread-COLD000001-1790000000.000006.json"
echo '{"state":"paused"}' > "$tmp/agent-hhhhhh.json"
echo '{"sessions":"agent-gggggg"}' > "$tmp/thread-C0AB12CD3-1790000000.000005.json"
echo '{"state":"paused","profile":"team-a"}' > "$tmp/agent-gggggg.json"
printf 'PROFILE_OPEN=team-a\nCHANNEL_GATES=COLD000001:CPRIV00001\nCHANNEL_GATES=CGATED0001:CPRIV00001\n' > "$tmp/bot.env"
printf 'k3y' > "$tmp/hmac"
FXA_SESSION_DIR="$tmp" FXA_BOT_ENV="$tmp/bot.env" FXA_TEAMS_DIR="$tmp/none" FXA_DASHBOARD_HMAC_FILE="$tmp/hmac" python3 - "$(dirname "$0")/../dashboard" "$tmp/ctl" <<'PY'
import os, sys, time
sys.path.insert(0, sys.argv[1]); import server, testkit
server.CTL, server.PIPELINE = sys.argv[2], "test"
base = testkit.start(server.Handler)
fail = 0
def get(q, viewer=None, key=b"k3y"):
    h = testkit.sig(viewer, "GET", "/api/watch/events", key=key) if viewer else {}
    st, hd, b = testkit.request(f"{base}/api/watch/events?thread={q}", headers=h, timeout=10)
    return (st, hd.get("Content-Type"), b.decode()) if st < 400 else (st, None, "")
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
check("an FxA session with watch_narrow 1, no signed viewer: 403", 403, get("C0AB12CD3:1790000000.000007")[0])
check("an FxA session with watch_narrow 1, a signed dashboard user: watched", 200, get("C0AB12CD3:1790000000.000007", "user@example.com")[0])
check("watch_narrow: an FxA session with the flag is narrow, one without is not",
      (True, False), (server.watch_narrow("fxa", "C0OPEN", None, {}, set(), True), server.watch_narrow("fxa", "C0OPEN", None, {}, set(), False)))
check("a gated channel, no signed viewer: 403", 403, get("CGATED0001:1790000000.000004")[0])
check("a gated channel, a signature with another key: 403", 403, get("CGATED0001:1790000000.000004", "user@example.com", b"other")[0])
check("a gated channel, a signed dashboard user: watched", 200, get("CGATED0001:1790000000.000004", "user@example.com")[0])
check("an open team, no signed viewer: watched", 200, get("C0AB12CD3:1790000000.000005")[0])
check("the last CHANNEL_GATES line wins, as in the bot", 200, get("COLD000001:1790000000.000006")[0])
os.environ["FXA_BOT_ENV"] = "/nonexistent"
check("no bot .env: a FxA session is gated", 403, get("C0AB12CD3:1791135361.015169")[0])
check("an unknown thread: 404", 404, get("C0AB12CD3:1700000000.000001")[0])
check("a bad thread: 400", 400, get("..%2Fx")[0])
sys.exit(fail)
PY
