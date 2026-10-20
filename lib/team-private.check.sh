#!/usr/bin/env bash
# Offline check for dashboard/server.py team_private (the teams feed's flag answers with no 'profile show') and its listen backlog.
#   bash lib/team-private.check.sh
set -u
here="$(cd "$(dirname "$0")" && pwd)"
python3 - "$here/../dashboard" <<'PY'
import sys, subprocess
sys.path.insert(0, sys.argv[1]); import server
fail = 0
def check(name, want, got):
    global fail
    print(("ok   " if want == got else "FAIL ") + name + ("" if want == got else f": want [{want}] got [{got}]")); fail |= want != got
calls = []
class R: returncode, stdout = 0, '{"private": false}'
def run(cmd, **kw): calls.append(cmd[2]); return R()
subprocess.run = server.subprocess.run = run
server.TEAMS = server.Feed("teams", [], 300, 600)
server.TEAMS.data = [{"profile": "fxa", "private": False}, {"profile": "secret", "private": True}, {"profile": "noflag"}]
check("a team in the feed answers from it, with no profile show", (False, True, True, []), (server.team_private("fxa"), server.team_private("secret"), server.team_private("noflag"), calls))
check("a team the feed does not list falls back to profile show", (False, ["ghost"]), (server.team_private("ghost"), calls))
server.TEAMS.data = None; calls.clear(); server._PRIVATE.clear()
check("no feed data yet: profile show, as before", (False, ["fxa"]), (server.team_private("fxa"), calls))
import inspect
check("the server listens with a backlog of 64, not the default 5, so a poll's burst of connections is not dropped",
      (64, True), (server.Server.request_queue_size, "Server((os.environ" in inspect.getsource(server)))
sys.exit(fail)
PY
