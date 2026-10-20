#!/usr/bin/env bash
# Offline check of /api/overview: the last 180 days of stats rows with only the Overview's fields, the merged PRs, the LLM summary, and an ETag.
#   bash lib/dashboard-overview.check.sh
set -u
python3 - "$(dirname "$0")/../dashboard" <<'PY'
import sys, threading, time, json, urllib.request, urllib.error
sys.path.insert(0, sys.argv[1]); import server
from http.server import ThreadingHTTPServer
now = time.time(); iso = lambda d: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now - d * 86400))
stats = {"rows": [{"at": iso(1), "src": "pipeline", "usd": 1.5, "pr": True, "min": 20, "profile": "fxa", "compute_usd": 0.1, "key": "FXA-1", "busy_s": 9},
                  {"at": iso(400), "src": "slack", "usd": 9, "pr": False, "min": 3, "profile": "fxa"},
                  {"at": "not a time", "src": "pass", "usd": 1}],
         "prs": [{"n": 1, "merged": iso(2), "title": "a"}, {"n": 2, "merged": None}, {"n": 3, "merged": iso(500)}],
         "llm": {"hour_usd": 0.42, "days": [{"day": str(i), "usd": i} for i in range(20)], "runs": {"x": 1},
                 "models": [{"day": "a", "model": "opus", "usd": 1.25}, {"day": "b", "model": "opus", "usd": 2}, {"day": "b", "model": None, "usd": 0.5}]}}
fail = 0
def check(name, want, got):
    global fail
    print(("ok   " if want == got else "FAIL ") + name + ("" if want == got else f": want [{want}] got [{got}]")); fail |= want != got
o = server.overview_slice(stats, now)
check("rows: only the last 180 days, a bad time left out", 1, len(o["rows"]))
check("rows: only the Overview's fields, in column order", [o["cols"], o["rows"][0][1:]], [["ms", "src", "usd", "pr", "min", "profile", "compute_usd"], ["pipeline", 1.5, 1, 20, "fxa", 0.1]])
check("rows: the time is epoch ms", True, abs(o["rows"][0][0] / 1000 - (now - 86400)) < 2)
check("merged: only merged PRs in the window", [iso(2)], o["merged"])
check("llm: the hour, the last 14 days and per-model totals, no per-run map",
      [0.42, 14, "6", {"opus": 3.25, "": 0.5}, False], [o["llm"]["hour_usd"], len(o["llm"]["days"]), o["llm"]["days"][0]["day"], o["llm"]["models"], "runs" in o["llm"]])
check("the same stats on the same day give the same object (cached)", True, server.overview_slice(stats, now) is o)
check("new stats give a new slice", False, server.overview_slice(dict(stats), now) is o)
check("an unread PR list is null, not an empty list, and prs_at passes through", [None, 99], [server.overview_slice({"rows": [], "prs_at": 99}, now)["merged"], server.overview_slice({"rows": [], "prs": [], "prs_at": 99}, now)["prs_at"]])
f = server.Feed("stats", [], 60, 30); f.data, f.fetched_at = stats, now; server.STATS = f
srv = ThreadingHTTPServer(("127.0.0.1", 0), server.Handler); threading.Thread(target=srv.serve_forever, daemon=True).start()
def get(tag=None):
    h = {"Host": "localhost", **({"If-None-Match": tag} if tag else {})}
    try:
        with urllib.request.urlopen(urllib.request.Request(f"http://127.0.0.1:{srv.server_port}/api/overview", headers=h), timeout=10) as r:
            return r.status, r.headers.get("ETag"), r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.headers.get("ETag"), e.read()
code, tag, body = get()
check("GET: 200 with an ETag and the slice", (200, True, 1), (code, bool(tag), len(json.loads(body)["rows"])))
check("GET: the same ETag back is a 304 with no body", (304, b""), (get(tag)[0], get(tag)[2]))
f.data = None
check("GET with no stats yet: an error and no ETag", (200, None, "stats unavailable"), (lambda c, t, b: (c, t, json.loads(b).get("error")))(*get()))
sys.exit(fail)
PY
