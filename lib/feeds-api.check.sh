#!/usr/bin/env bash
# Offline check that dashboard/server.py answers a failed errors read with 503 and a reason, never an empty list.
#   bash lib/feeds-api.check.sh
set -u
tmp="$(mktemp -d "${TMPDIR:-/tmp}/feeds-api.XXXXXX")"; trap 'rm -rf "$tmp"' EXIT
printf '#!/bin/sh\nexit 1\n' > "$tmp/ctl"; chmod +x "$tmp/ctl"
FXA_TEAMS_DIR="$tmp/none" python3 - "$(dirname "$0")/../dashboard" "$tmp" <<'PY'
import json, sys, threading, urllib.error, urllib.request
sys.path.insert(0, sys.argv[1]); import server
from http.server import ThreadingHTTPServer
server.CTL, server.PIPELINE = sys.argv[2] + "/ctl", "test"
srv = ThreadingHTTPServer(("127.0.0.1", 0), server.Handler); threading.Thread(target=srv.serve_forever, daemon=True).start()
fail = 0
def check(name, want, got):
    global fail
    ok = want == got; fail |= not ok
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f": want {want!r} got {got!r}"))
def get(p):
    try:
        with urllib.request.urlopen(urllib.request.Request(f"http://127.0.0.1:{srv.server_port}{p}", headers={"Host": "localhost"}), timeout=30) as r: return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e: return e.code, json.loads(e.read())
s, b = get("/api/errors"); check("a failed first errors read is 503 with a reason, not []", (503, True), (s, isinstance(b, dict) and "error" in b))
print("all checks pass" if not fail else "", end="\n" if not fail else ""); sys.exit(fail)
PY
