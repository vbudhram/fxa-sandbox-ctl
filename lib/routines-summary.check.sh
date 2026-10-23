#!/usr/bin/env bash
# Offline check of /api/routines/summary for the Teams page: admins only, counts that leave a paused
# routine out of its team, a fixed 503 when the store cannot be read, and no prompt, report or channel.
#   bash lib/routines-summary.check.sh
set -u
command -v sqlite3 >/dev/null || { echo "skip: needs sqlite3"; exit 0; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
here="$(cd "$(dirname "$0")" && pwd)"
export FXA_DB="$tmp/fxa.db"; source "$here/config.sh"; source "$here/db.sh"; db_init >/dev/null
now=$(date +%s); old=$((now - 40 * 86400))
d() { printf '{"name":"%s","prompt":"SECRET-PROMPT","channel":"C0SECRET"%s}' "$1" "${2:-}"; }
sqlite3 "$FXA_DB" "
INSERT INTO routines (id, team, data, paused) VALUES (1,'fxa','$(d A ',"schedule":"daily 09:00","zone":"UTC"')',0),(2,'fxa','$(d B ',"schedule":"daily 09:00","zone":"Nowhere/Bad"')',0),(3,'fxa','$(d C)',0),(4,'fxa','$(d D)',0),(5,'fxa','$(d E)',1),(6,'crew','$(d F)',0);
INSERT INTO routine_runs (routine_id, period, state, reason, session, cost_usd, report, ended_at) VALUES
 (1,'p1','report',NULL,'agent-a1',0.5,'SECRET-REPORT',$((now-3600))),
 (2,'p1','ok',NULL,'agent-b0',1.0,NULL,$((now-7200))),(2,'p2','failed','the turn stopped','agent-b1',0.25,NULL,$((now-600))),
 (3,'p1','failed','x','agent-c1',0.1,NULL,$((now-9000))),(3,'p2','ok',NULL,'agent-c2',0.2,NULL,$((now-60))),
 (5,'p1','missed','the tick did not run',NULL,NULL,NULL,$((now-100))),
 (6,'p0','ok',NULL,'agent-f0',9.0,NULL,$old);
INSERT INTO routine_runs (routine_id, period, state, session, started_at) VALUES (4,'p1','started','agent-d1',$((now-30)));"
printf k1 > "$tmp/hmac"
FXA_DASHBOARD_HMAC_FILE="$tmp/hmac" TEAM_ADMINS="admin@example.com" python3 - "$here/../dashboard" "$tmp" <<'PY'
import json, os, sys, time
sys.path.insert(0, sys.argv[1]); import server, fxadb, testkit
tmp = sys.argv[2]
base = testkit.start(server.Handler)
fail = 0
def check(name, want, got):
    global fail
    print(("ok   " if want == got else "FAIL ") + name + ("" if want == got else f": want {want!r} got {got!r}")); fail |= want != got
def sig(user, path): return testkit.sig(user, "GET", path)
def get(headers=None):
    st, _, b = testkit.request(base + "/api/routines/summary", headers=headers)
    return st, b.decode()
P = "/api/routines/summary"
check("no signed user: 401", 401, get()[0])
check("a signed user who is not a team admin: 403", 403, get(sig("other@example.com", P))[0])
code, body = get(sig("admin@example.com", P)); s = json.loads(body); t = s["teams"]["fxa"]
check("an admin gets the summary", 200, code)
check("the team counts routines, paused, live and failed (a paused failed routine is left out)", (5, 1, 1, 1), (t["routines"], t["paused"], t["live"], t["failed"]))
check("the last failed run is B's newest", ("B", "the turn stopped", "agent-b1"), (t["last_failed"]["name"], t["last_failed"]["reason"], t["last_failed"]["session"]))
check("a routine whose newest run is ok is not failed; the paused one stays failed for itself", (False, True, False), (s["routines"]["3"]["failed"], s["routines"]["5"]["failed"], s["routines"]["1"]["failed"]))
check("runs and cost count the last 30 days only", (0, 0.0), (s["routines"]["6"]["runs_30d"], s["routines"]["6"]["cost_30d"]))
check("the 30-day team cost", 2.05, t["cost_30d"])
r = s["routines"]; nx = r["1"]["next"]
check("A's next run is its next 09:00 UTC, within a day", (True, True), (isinstance(nx, int) and 0 < nx - time.time() <= 86400, time.gmtime(nx)[3:5] == (9, 0) if nx else False))
check("no next run for a bad zone, no schedule, or a paused routine", (None, None, None, None), (r["2"]["next"], r["3"]["next"], r["4"]["next"], r["5"]["next"]))
check("each routine has its name, team and paused", ("E", "fxa", True), (r["5"]["name"], r["5"]["team"], r["5"]["paused"]))
check("each routine's template (blank when none) and its lowest and highest run cost in 30 days", ("blank", 0.25, 1.0, None, None),
      (r["2"]["template"], r["2"]["cost_min_30d"], r["2"]["cost_max_30d"], r["6"]["cost_min_30d"], r["4"]["cost_max_30d"]))
check("no prompt, report or channel in the body", (False, False, False), ("SECRET-PROMPT" in body, "SECRET-REPORT" in body, "C0SECRET" in body))
fxadb.PATH = f"{tmp}/missing/fxa.db"
code, body = get(sig("admin@example.com", P))
check("a store that cannot be read: 503 with a fixed text, no path", (503, "the routine store cannot be read", False), (code, json.loads(body)["error"], "missing" in body))
sys.exit(fail)
PY
