#!/usr/bin/env bash
# Offline check of /api/teams: the profile diff, the bot .env access read, and the team issues.
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
FXA_BOT_ENV="$tmp/bot.env.base" python3 - "$(dirname "$0")/../dashboard" "$tmp" <<'PY'
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
check("the access source is the file name only, with no host path", ("bot.env.base", None, False), (b["access_source"]["file"], b["access_error"], tmp in raw))

os.environ["FXA_BOT_ENV"] = f"{tmp}/missing.env"
b = json.loads(get()[1]); t = {x["profile"]: x for x in b["teams"]}
check("an unreadable bot env: access null, the error set, no nobody rule, no orphans",
      (None, "FileNotFoundError", None, [], []),
      (t["solo"]["access"], b["access_error"], b["access_source"], [i for i in t["solo"]["issues"] if i["level"] == "warn"], b["issues"]))
# A team record's own rules (the teams index), as counts: active or not, never a Slack user ID.
recs = {"rusty": {"status": "active", "jira": "RUST", "access": {"users": ["U0EEEE666", "U0FFFF777"], "channels": ["C0RUSTY1"], "jira_prefixes": ["RS"]}},
        "drafty": {"status": "draft", "access": {"open": True, "users": ["U0EEEE666"]}}}
check("an active record: its users, channels and Jira keys", {"open": False, "users": 2, "channels": 1, "jira": ["RS", "RUST"], "record": True, "status": "active"},
      server.team_access("rusty", None, recs))
check("a draft record is open to nobody, whatever it says", (False, 0, "draft"), tuple(server.team_access("drafty", None, recs)[k] for k in ("open", "users", "status")))
check("no Slack user ID from a record reaches the access", False, "U0EEEE" in json.dumps(server.team_access("rusty", None, recs)))
per, _ = server.team_issues([{"profile": "drafty", "repos": []}], None, recs)
check("a draft record: nobody can start it", True, ("warn", "nobody can start it") in [(x["level"], x["text"]) for x in per[0]])
idx = Path(tmp) / "teams"; idx.mkdir(); (idx / "index.json").write_text(json.dumps({"schema": 1, "teams": recs}))
os.environ["FXA_TEAMS_DIR"] = str(idx)
check("read_records reads the index; a missing one is empty", (["drafty", "rusty"], {}),
      (sorted(server.read_records()), (os.environ.update(FXA_TEAMS_DIR=f"{tmp}/none"), server.read_records())[1]))
# Spend against the caps (the LLM proxy's files), and the issues it raises; nothing about an error leaks.
import time as _t
month = _t.strftime("%Y-%m", _t.gmtime()); now = int(_t.time())
px = Path(tmp) / "proxy" / "teams"; px.mkdir(parents=True)
(px / "pyfxa-team.json").write_text(json.dumps({"month_usd": 10})); (px / "pyfxa-team.spend.json").write_text(json.dumps({"month": month, "month_usd": 10}))
(px / "crew.json").write_text(json.dumps({"month_usd": 100})); (px / "crew.spend.json").write_text(json.dumps({"month": month, "month_usd": 92}))
(px / "solo.json").write_text("[1]")
os.environ["FXA_LLM_PROXY_DIR"] = str(px.parent)
check("a team's spend this month against its cap", (10, 10, None), tuple(server.team_budget("pyfxa-team", now)[0][k] for k in ("month_usd", "month_cap", "day_cap")))
check("a caps file of the wrong shape: no budget, the fixed word", (None, "unreadable"), server.team_budget("solo", now))
check("a name that is not a profile builds no path", (None, None), server.team_budget("../x", now))
os.environ["FXA_LLM_PROXY_DIR"] = f"{tmp}/no-proxy"
check("no proxy teams folder: no budget, no error", (None, None), server.team_budget("crew", now))
os.environ["FXA_LLM_PROXY_DIR"] = str(px.parent)
iss = lambda t: [(x["level"], x["text"]) for x in server.team_issues([dict({"profile": t, "repos": []}, **dict(zip(("budget", "budget_error"), server.team_budget(t, now))))], None)[0][0]]
check("a reached cap is a warn", True, ("warn", "monthly spend cap reached") in iss("pyfxa-team"))
check("92% of the cap is info", True, ("info", "monthly spend at 92% of the cap") in iss("crew"))
check("unreadable spend is info, not a warn", (True, False), (("info", "spend cannot be read") in iss("solo"), any(l == "warn" for l, _ in iss("solo"))))
b = json.loads(get()[1]); raw = json.dumps(b)
check("the body names no host path or exception", (False, False, False), ("/home/" in raw, "/Users/" in raw, "ValueError" in raw))
check("a profile that did not load has no budget", None, {x["profile"]: x for x in b["teams"]}["broken"].get("budget"))
# The last profile test, from the exact final lines of teams.sh and fresh files only.
td = Path(tmp) / "tteams"; td.mkdir(); os.environ["FXA_TEAMS_DIR"] = str(td)
(td / "rusty.json").write_text("{}")
def files(gen, log=None, tested=None, pid=None, log_age=0):
    for e in (".gen", ".test.log", ".tested", ".test.pid"):
        (td / f"rusty{e}").unlink(missing_ok=True)
    (td / "rusty.gen").write_text(f"{gen}\n"); os.utime(td / "rusty.gen", (now - 100, now - 100))
    if log is not None:
        (td / "rusty.test.log").write_text(log); os.utime(td / "rusty.test.log", (now - log_age, now - log_age))
    if tested is not None: (td / "rusty.tested").write_text(f"{tested}\n")
    if pid is not None: (td / "rusty.test.pid").write_text(str(pid))
    return server.team_test("rusty", now)
r = files(14, "SECRETLINE\nfailed: team rusty stays as it is\n", tested=12)
check("a failed test", ("failed", None), (r["result"], r["tested"] if False else None))
check("running: a live pid, no final line, a fresh log", "running", files(14, "booting\n", pid=os.getpid())["result"])
check("a forged passed line for another team is not a result", None, files(14, "passed: team x may be activated at generation 14\n")["result"])
check("a log older than the generation is not a result", None, files(14, "failed: team rusty stays as it is\n", log_age=500)["result"])
check("passed at the current generation", ("passed", 14), tuple(files(14, "passed: team rusty may be activated at generation 14\n")[k] for k in ("result", "generation")))
check("passed at an older generation is not passed", None, files(15, "passed: team rusty may be activated at generation 14\n")["result"])
check("tested counts when it is not older than the generation", 14, files(14, tested=14)["tested"])
# Test, then Activate: Activate writes generation 15 after the test. The pass still shows, by value.
files(14, "passed: team rusty may be activated at generation 14\n", tested=14); (td / "rusty.gen").write_text("15\n"); os.utime(td / "rusty.gen", (now, now))
r = server.team_test("rusty", now)
check("after Activate: no result from the older log, tested 14 at generation 15", (None, 14, 15), (r["result"], r["tested"], r["generation"]))
per, _ = server.team_issues([{"profile": "rusty", "repos": [], "test": r}], None, {"rusty": {"status": "active", "generation": "15"}})
check("after Activate: the last-passed info shows", True, any(x["text"] == "last passed at generation 14; later edits did not change what a runner uses" for x in per[0]))
check("a team with no record has no test", None, server.team_test("crew", now))
recs2 = {"rusty": {"status": "active", "generation": "13"}}
per, _ = server.team_issues([{"profile": "rusty", "repos": [], "test": {"tested": 12}}], None, recs2)
check("an active team tested at an older generation: info", True, ("info", "last passed at generation 12; later edits did not change what a runner uses") in [(x["level"], x["text"]) for x in per[0]])
# The leak check reads a log of a team that /api/teams lists (crew), and shows that team_test ran on it.
(td / "crew.json").write_text("{}"); (td / "crew.gen").write_text("3\n"); os.utime(td / "crew.gen", (now - 100, now - 100))
(td / "crew.test.log").write_text("SECRETLINE\nfailed: team crew stays as it is\n")
code, body = get(); crew = {x["profile"]: x for x in json.loads(body)["teams"]}["crew"]
check("no test log text reaches /api/teams, and the listed team has its result", (False, "failed"), ("SECRETLINE" in body, crew["test"]["result"]))
srv.shutdown(); sys.exit(fail)
PY
