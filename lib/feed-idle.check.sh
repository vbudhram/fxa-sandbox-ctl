#!/usr/bin/env bash
# Offline check for dashboard/server.py feed gating: a gated feed refreshes only while a viewer is around,
# and the first request after an idle spell refreshes it at once.
#   bash lib/feed-idle.check.sh
set -u
python3 - "$(dirname "$0")/../dashboard" <<'PY'
import sys, time, threading
sys.path.insert(0, sys.argv[1]); import server
fail = 0
def check(name, want, got):
    global fail
    print(("ok   " if want == got else "FAIL ") + name + ("" if want == got else f": want [{want}] got [{got}]")); fail |= want != got
runs = []
class F(server.Feed):
    def refresh(self, already_claimed=False):
        runs.append(self.name); self.data = {}; self.refreshing = False; return True
f, t = F("snapshot", [], 60, 30), F("teams", [], 300, 600)
f.gated = True; server.GATED[:] = [f]
server.LAST_SEEN[0] = time.time()
check("with a viewer in the last 10 min, a gated feed refreshes", (True, ["snapshot"]), (f.tick(), runs[:]))
server.LAST_SEEN[0] = time.time() - server.IDLE_S - 1; runs.clear()
check("with no viewer for 10 min, a gated feed skips its refresh; an ungated one does not", (False, True, ["teams"]), (f.tick(), t.tick(), runs[:]))
runs.clear(); woke = server.seen(); time.sleep(0.2)
check("the first request after the idle spell refreshes the gated feed at once", (["snapshot"], ["snapshot"]), ([x.name for x in woke], runs[:]))
runs.clear()
check("a request while the viewer is around starts nothing extra", ([], []), (server.seen(), runs[:]))
g = F("stats", [], 60, 30); g.gated = True; server.LAST_SEEN[0] = 0; runs.clear()
check("a gated feed with no data yet still fills once", (True, ["stats"]), (g.tick(), runs[:]))
sys.exit(fail)
PY
