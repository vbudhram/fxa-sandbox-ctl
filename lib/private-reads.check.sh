#!/usr/bin/env bash
# Offline check that a private-repo team's session (history, tail, media, its request and last output in
# /api/sessions and /api/snapshot) reaches only a signed team admin.
#   bash lib/private-reads.check.sh
set -u
tmp="$(mktemp -d "${TMPDIR:-/tmp}/private-reads.XXXXXX")"; trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/ctl" <<'SH'
#!/bin/sh
case "$*" in
  *"session history"*) echo '{"turns":["the private turn"]}' ;;
  *"--pipeline privteam profile show"*) echo '{"private":true}' ;;
  *"profile show"*) echo '{"private":false}' ;;
esac
SH
chmod +x "$tmp/ctl"; printf k1 > "$tmp/hmac"; mkdir -p "$tmp/sess/agent-priv01.media" "$tmp/sess/agent-pub001.media"
echo '{"key":"agent-priv01","profile":"privteam"}' > "$tmp/sess/agent-priv01.json"; echo '{"key":"agent-pub001","profile":"fxa"}' > "$tmp/sess/agent-pub001.json"
printf png > "$tmp/sess/agent-priv01.media/a.png"; printf png > "$tmp/sess/agent-pub001.media/a.png"; : > "$tmp/db"
FXA_SESSION_DIR="$tmp/sess" FXA_DASHBOARD_HMAC_FILE="$tmp/hmac" TEAM_ADMINS="admin@example.com" FXA_TEAMS_DIR="$tmp/none" python3 - "$(dirname "$0")/../dashboard" "$tmp" <<'PY'
import json, sys, time
sys.path.insert(0, sys.argv[1]); import server, testkit
t = sys.argv[2]
server.CTL, server.PIPELINE = t + "/ctl", "test"
server.agent_tail = lambda key: ["the private screen"]
server.fxadb.PATH = t + "/db"
server.fxadb.connect = lambda readonly=False: type("C", (), {"close": lambda self: None})()
rows = [{"key": "agent-priv01", "profile": "privteam", "request": "fix the secret", "media": [{"name": "a.png"}], "last_text": "x"},
        {"key": "agent-pub001", "profile": "fxa", "request": "fix the page", "media": [{"name": "a.png"}]}, {"key": "agent-gone01", "deleted": True}]
server.fxadb.sessions_since = lambda con, since, d: {"cursor": 9, "rows": rows}
server.FULL = server.Feed("snapshot", [], 60, 30); server.STATS = server.Feed("stats", [], 60, 30); server.AGENTS = server.Feed("agents", [], 15, 30)
server.AGENTS.data, server.AGENTS.fetched_at = {"sessions": [dict(rows[0], agent={"last_text": "secret out", "last_tool": "cat key"}), rows[1]]}, time.time()
base = testkit.start(server.Handler)
fail = 0
def check(name, want, got):
    global fail
    ok = want == got; fail |= not ok
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f": want {want!r} got {got!r}"))
def get(pq, user=None):
    st, hd, b = testkit.request(base + pq, headers=testkit.sig(user, "GET", pq.split("?")[0]) if user else None)
    if st >= 400: return st, None
    return st, json.loads(b) if hd.get("Content-Type", "").startswith("application/json") else b.decode()
codes = lambda key, user=None: [get(p, user)[0] for p in (f"/api/history?key={key}", f"/api/tail?key={key}", f"/api/media?key={key}&name=a.png")]
check("a non-admin gets 403 from history, tail and media of a private team's session", [403, 403, 403], codes("agent-priv01", "other@example.com"))
check("an upper-case key reaches the same session: AGENT-PRIV01 is refused on tail", 403, get("/api/tail?key=AGENT-PRIV01", "other@example.com")[0])
check("with no signed user too", [403, 403, 403], codes("agent-priv01"))
check("a session whose record cannot be read counts as private", 403, get("/api/history?key=agent-none01")[0])
check("a team admin reads them", [200, 200, 200], codes("agent-priv01", "admin@example.com"))
check("a public team's session is open to any viewer", [200, 200, 200], codes("agent-pub001"))
s = {r["key"]: r for r in get("/api/sessions?since=1")[1]["rows"]}
check("/api/sessions: a private session has no request, media or last text for a non-admin", [], [k for k in ("request", "media", "last_text") if k in s["agent-priv01"]])
check("/api/sessions: a public session and a deleted row are as they were", ("fix the page", True), (s["agent-pub001"]["request"], s["agent-gone01"]["deleted"]))
check("/api/sessions: an admin sees the request", "fix the secret", {r["key"]: r for r in get("/api/sessions?since=1", "admin@example.com")[1]["rows"]}["agent-priv01"]["request"])
a = {x["key"]: x for x in get("/api/snapshot")[1]["agents"]["sessions"]}
check("/api/snapshot: a private session's request and the agent's last output are gone", (None, {}), (a["agent-priv01"].get("request"), a["agent-priv01"]["agent"]))
check("/api/snapshot: the feed's own copy is not changed", "secret out", server.AGENTS.data["sessions"][0]["agent"]["last_text"])
check("/api/snapshot: an admin sees the agent's last output", "secret out", {x["key"]: x for x in get("/api/snapshot", "admin@example.com")[1]["agents"]["sessions"]}["agent-priv01"]["agent"]["last_text"])
sys.exit(fail)
PY
