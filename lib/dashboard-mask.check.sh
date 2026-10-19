#!/usr/bin/env bash
# Offline check that the dashboard API masks known token formats in tail and history, as the watch page does.
#   bash lib/dashboard-mask.check.sh
set -u
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
# The ctl: tail and session history print agent text with a run token and a GitHub token.
cat > "$tmp/ctl" <<'SH'
#!/bin/sh
case "$*" in
  *tail*) echo "curl -H 'Authorization: Bearer fxm_abcdefgh12345678' http://x" ;;
  *history*) echo '[{"text":"push with ghs_abcdefgh12345678 now"}]' ;;
  *"profile show"*) echo '{"private":false}' ;;
esac
SH
chmod +x "$tmp/ctl"
# A public team's session: a private one's history is a team admin's (lib/private-reads.check.sh).
echo '{"key":"agent-abcd12","profile":"fxa"}' > "$tmp/agent-abcd12.json"
FXA_SESSION_DIR="$tmp" FXA_TEAMS_DIR="$tmp/none" python3 - "$(dirname "$0")/../dashboard" "$tmp/ctl" "$(dirname "$0")/session.sh" <<'PY'
import re, sys, threading, urllib.request
sys.path.insert(0, sys.argv[1]); import server
from http.server import ThreadingHTTPServer
server.CTL, server.PIPELINE = sys.argv[2], "test"
srv = ThreadingHTTPServer(("127.0.0.1", 0), server.Handler); threading.Thread(target=srv.serve_forever, daemon=True).start()
fail = 0
def get(path):
    req = urllib.request.Request(f"http://127.0.0.1:{srv.server_port}{path}", headers={"Host": "localhost"})
    with urllib.request.urlopen(req, timeout=10) as r: return r.read().decode()
def check(name, want, got):
    global fail
    ok = want == got; fail |= not ok
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f": want {want!r} got {got!r}"))
t = get("/api/tail?key=FXA-1")
check("tail: the run token is masked", (True, False), ("fxm_<masked>" in t, "abcdefgh12345678" in t))
h = get("/api/history?key=agent-abcd12")
check("history: the GitHub token is masked", (True, False), ("ghs_<masked>" in h, "abcdefgh12345678" in h))
import time
server.FULL = server.Feed("snapshot", [], 60, 30); server.STATS = server.Feed("stats", [], 60, 30)
server.AGENTS = server.Feed("agents", [], 15, 30)
server.AGENTS.data, server.AGENTS.fetched_at = {"runners": [{"key": "FXA-1", "agent": {"last_tool": "curl -H 'Authorization: Bearer fxm_abcdefgh12345678'", "last_text": "pushed with ghs_abcdefgh12345678"}}]}, time.time()
sn = get("/api/snapshot")
check("snapshot: the floor's last output line is masked (fxm_, ghs_)", (True, True, False), ("fxm_<masked>" in sn, "ghs_<masked>" in sn, "abcdefgh12345678" in sn))
jq = re.search(r'gsub\("\(\?<p>(.*?)\)(\[A-Za-z0-9_-\]\{8,\})"', open(sys.argv[3]).read())
check("the server's pattern is the watch page's", server.MASK.pattern, "(" + jq.group(1) + ")" + jq.group(2))
sys.exit(fail)
PY
