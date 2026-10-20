#!/usr/bin/env bash
# Offline check that /api/errors and /api/stats send an ETag and answer a matching If-None-Match with 304 and no body.
#   bash lib/dashboard-etag.check.sh
set -u
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
printf '#!/bin/sh\ncase "$*" in *"errors --json"*) echo %s ;; esac\n' "'[{\"sig\":\"a1\",\"status\":\"open\"}]'" > "$tmp/ctl"; chmod +x "$tmp/ctl"
python3 - "$(dirname "$0")/../dashboard" "$tmp/ctl" <<'PY'
import sys, threading, time, urllib.request, urllib.error
sys.path.insert(0, sys.argv[1]); import server
from http.server import ThreadingHTTPServer
server.CTL, server.PIPELINE = sys.argv[2], "test"
for name in ("FULL", "AGENTS", "STATS"):
    f = server.Feed(name.lower(), [], 60, 30); f.data, f.fetched_at = {"rows": [1, 2]}, time.time(); setattr(server, name, f)
srv = ThreadingHTTPServer(("127.0.0.1", 0), server.Handler); threading.Thread(target=srv.serve_forever, daemon=True).start()
fail = 0
def check(name, want, got):
    global fail
    print(("ok   " if want == got else "FAIL ") + name + ("" if want == got else f": want [{want}] got [{got}]")); fail |= want != got
def get(path, tag=None):
    h = {"Host": "localhost", **({"If-None-Match": tag} if tag else {})}
    try:
        with urllib.request.urlopen(urllib.request.Request(f"http://127.0.0.1:{srv.server_port}{path}", headers=h), timeout=10) as r:
            return r.status, r.headers.get("ETag"), r.headers.get("Cache-Control"), r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.headers.get("ETag"), e.headers.get("Cache-Control"), e.read()
for path in ("/api/errors", "/api/stats"):
    code, tag, cc, body = get(path)
    check(f"{path}: 200 with an ETag, cached only with revalidation", (200, True, "no-cache", True), (code, bool(tag), cc, len(body) > 0))
    check(f"{path}: the same ETag back is a 304 with no body", (304, tag, b""), get(path, tag)[0:2] + (get(path, tag)[3],))
    check(f"{path}: another ETag gets the full body", 200, get(path, '"other"')[0])
check("a route with a clock in it (the snapshot) keeps no-store and no ETag", (None, "no-store"), get("/api/snapshot")[1:3])
sys.exit(fail)
PY
