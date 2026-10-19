#!/usr/bin/env bash
# Offline check that GET /api/lessons shows a private team's lessons only to a signed team admin.
#   bash lib/lessons-api.check.sh
set -u
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
# The ctl: the lesson list, and profile show (privteam has a private repo, fxa does not).
cat > "$tmp/ctl" <<'SH'
#!/bin/sh
case "$*" in
  *"lessons --json"*) echo '[{"id":"a1","team":"fxa","text":"an fxa lesson"},{"id":"b2","team":"privteam","text":"a private lesson"},{"id":"c3","text":"an old lesson"},{"id":"d4","team":"ghost","text":"a team profile show cannot read"}]' ;;
  *"--pipeline privteam profile show"*) echo '{"private":true}' ;;
  *"--pipeline ghost profile show"*) exit 1 ;;
  *"profile show"*) echo '{"private":false}' ;;
esac
SH
chmod +x "$tmp/ctl"; printf k1 > "$tmp/hmac"
FXA_DASHBOARD_HMAC_FILE="$tmp/hmac" TEAM_ADMINS="admin@example.com" FXA_TEAMS_DIR="$tmp/none" python3 - "$(dirname "$0")/../dashboard" "$tmp/ctl" <<'PY'
import hashlib, hmac, json, sys, threading, time, urllib.request
sys.path.insert(0, sys.argv[1]); import server
from http.server import ThreadingHTTPServer
server.CTL, server.PIPELINE = sys.argv[2], "test"
srv = ThreadingHTTPServer(("127.0.0.1", 0), server.Handler); threading.Thread(target=srv.serve_forever, daemon=True).start()
fail = 0
def check(name, want, got):
    global fail
    ok = want == got; fail |= not ok
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f": want {want!r} got {got!r}"))
def ids(user=None):
    h = {"Host": "localhost"}
    if user:
        ts = str(int(time.time()))
        h.update({"X-Fxa-User": user, "X-Fxa-Time": ts, "X-Fxa-Sig": hmac.new(b"k1", f"{user}|{ts}|GET|/api/lessons".encode(), hashlib.sha256).hexdigest()})
    with urllib.request.urlopen(urllib.request.Request(f"http://127.0.0.1:{srv.server_port}/api/lessons", headers=h), timeout=10) as r:
        return [x["id"] for x in json.loads(r.read().decode())]
check("no signed user: no private team's lesson, nor one whose team cannot be read", ["a1", "c3"], ids())
check("a signed user who is not an admin: the same", ["a1", "c3"], ids("other@example.com"))
check("a signed team admin sees every lesson", ["a1", "b2", "c3", "d4"], ids("admin@example.com"))
sys.exit(fail)
PY
