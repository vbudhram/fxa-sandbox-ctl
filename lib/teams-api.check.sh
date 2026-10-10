#!/usr/bin/env bash
# Offline check of /api/teams: the profile diff, the bot.env.base access read, and the team issues.
#   bash lib/teams-api.check.sh
set -u
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
for p in fxa pyfxa-team broken solo crew; do mkdir -p "$tmp/profiles/$p"; : > "$tmp/profiles/$p/profile.conf"; done
# The ctl's profile list: broken did not load, so it is missing. Each run adds a line to the counter.
cat > "$tmp/list.json" <<'JSON'
[{"profile":"fxa","label":"fxa","read_only":false,"mcp":null,"defaults":[],"repos":[{"slug":"mozilla/fxa","role":"work","write":true,"why":null}]},
 {"profile":"pyfxa-team","label":"PyFxA team","read_only":false,"mcp":["github"],"defaults":[],"repos":[{"slug":"mozilla/PyFxA","role":"work","write":true,"why":null}]},
 {"profile":"solo","label":"solo","read_only":false,"mcp":[],"defaults":[],"repos":[{"slug":"mozilla/solo","role":"work","write":false,"why":"the GitHub App check failed"}]},
 {"profile":"crew","label":"crew","read_only":true,"mcp":null,"defaults":[],"repos":[{"slug":"mozilla/crew","role":"work","write":false,"why":"the profile is read-only"}]}]
JSON
printf '#!/bin/sh\necho run >> "%s/count"\ncat "%s/list.json"\n' "$tmp" "$tmp" > "$tmp/ctl"; chmod +x "$tmp/ctl"; : > "$tmp/count"
cat > "$tmp/bot.env.base" <<'ENV'
SLACK_BOT_TOKEN=xoxb-fake
PROFILE_OPEN=pyfxa-team
PROFILE_USERS=crew:U0AAAA111+U0AAAA222,x:,monitor:U0BBBB333,U0CCCC444:crew
PROFILE_CHANNELS=C123:ghost,C456:U0DDDD555
PROFILE_JIRA=PY:pyfxa-team
ENV
FXA_BOT_ENV_BASE="$tmp/bot.env.base" python3 - "$(dirname "$0")/../dashboard" "$tmp" <<'PY'
import json, os, sys, threading, urllib.error, urllib.request
from pathlib import Path
sys.path.insert(0, sys.argv[1]); import server
from http.server import ThreadingHTTPServer
tmp = sys.argv[2]
server.CTL, server.PROFILES_DIR = f"{tmp}/ctl", Path(tmp) / "profiles"
server.TEAMS = server.Feed("teams", ["profile", "list"], 300, 600)
srv = ThreadingHTTPServer(("127.0.0.1", 0), server.Handler); threading.Thread(target=srv.serve_forever, daemon=True).start()
fail = 0
def get(host="localhost"):
    req = urllib.request.Request(f"http://127.0.0.1:{srv.server_port}/api/teams", headers={"Host": host})
    try:
        with urllib.request.urlopen(req, timeout=10) as r: return r.status, r.read().decode()
    except urllib.error.HTTPError as e: return e.code, ""
def check(name, want, got):
    global fail
    ok = want == got; fail |= not ok
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f": want {want!r} got {got!r}"))
runs = lambda: len(open(f"{tmp}/count").read().splitlines())

first = [get() for _ in range(3)]
b = json.loads(first[0][1])
check("before the first refresh: 200, no teams, no age", (200, [], None), (first[0][0], b["teams"], b["age_seconds"]))
check("a GET never runs the ctl", 0, runs())
check("a bad Host gets 421", 421, get("evil.example")[0])

server.TEAMS.refresh()
st, raw = get(); b = json.loads(raw); t = {x["profile"]: x for x in b["teams"]}
lv = lambda p: [(i["level"], i["text"]) for i in t[p]["issues"]]
check("a dir missing from the list is a load error with a bad issue", (True, [("bad", "profile.conf did not load")]),
      (t["broken"].get("load_error"), lv("broken")))
check("PROFILE_OPEN opens pyfxa-team, and it has no issue", (True, []), (t["pyfxa-team"]["access"]["open"], lv("pyfxa-team")))
check("fxa is open by a rule built into the bot", "built-in", t["fxa"]["access"]["open"])
check("users is a count, channels a count, jira the prefixes", (2, 0, ["PY"]),
      (t["crew"]["access"]["users"], t["pyfxa-team"]["access"]["channels"], t["pyfxa-team"]["access"]["jira"]))
check("the empty pair x: is dropped, so no issue names x", [], [i for i in b["issues"] if "'x'" in i["text"]])
check("unknown teams in the rules are top-level warns", ["PROFILE_CHANNELS has an entry that is not a team name", "PROFILE_CHANNELS names unknown team 'ghost'",
       "PROFILE_USERS has an entry that is not a team name", "PROFILE_USERS names unknown team 'monitor'"],
      sorted(i["text"] for i in b["issues"] if i["level"] == "warn"))
check("no token and no Slack user ID reach the page", [], [s for s in ("xoxb", "U0AAAA", "U0BBBB", "U0CCCC", "U0DDDD", "C123") if s in raw])
check("a team with no open and no users: nobody can start it", True, ("warn", "nobody can start it") in lv("solo"))
check("a failed App check is info, write unknown", [("info", "mozilla/solo: GitHub App check failed; write unknown")],
      [x for x in lv("solo") if x[0] == "info"])
check("a read-only team's no-write repo is no issue", [], [x for x in lv("crew") if x[0] == "info"])
check("the access source is the file and its mtime", (f"{tmp}/bot.env.base", None), (b["access_source"]["path"], b["access_error"]))

os.environ["FXA_BOT_ENV_BASE"] = f"{tmp}/missing.env"
b = json.loads(get()[1]); t = {x["profile"]: x for x in b["teams"]}
check("an unreadable bot env: access null, the error set, no nobody rule, no orphans",
      (None, "FileNotFoundError", None, [], []),
      (t["solo"]["access"], b["access_error"], b["access_source"], [i for i in t["solo"]["issues"] if i["level"] == "warn"], b["issues"]))
srv.shutdown(); sys.exit(fail)
PY
