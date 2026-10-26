#!/usr/bin/env bash
# Offline check that live-render.sh puts every live feed the dashboard reads in its fixture, the errors list included.
# It runs a copy in a temporary tree whose vm.sh is a stub, with this tree's dashboard.
#   bash skills/fxa-ctl-dev/live-render.check.sh
set -u
here="$(cd "$(dirname "$0")" && pwd)"; root="$(cd "$here/../.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/skills/fxa-ctl-dev" "$tmp/skills/fxa-manager"; ln -s "$root/dashboard" "$tmp/dashboard"
cp "$here/live-render.sh" "$here/page.sh" "$tmp/skills/fxa-ctl-dev/"
cat > "$tmp/skills/fxa-manager/vm.sh" <<'SH'
#!/bin/bash
case "$*" in *live-render-team*) echo "$*" >> "$(dirname "$0")/team-calls"; echo '{"/api/routines/summary": {"teams": {}}, "/api/teams/crew/memory": {"on": true, "entries": [{"id": "mem-0000aaaa", "text": "A fact"}]}}'; exit 0 ;; esac
[ "$1" = run ] && { echo '{"agent-rt0001": [{"key": "agent-rt0001", "routine_run": 3, "routine_name": "Code review", "state": "stopped"}, "This run was started on a schedule"]}'; exit 0; }
case "$2" in
  snapshot) echo '{"snapshot": {}, "agents": {"sessions": []}}' ;;
  stats) echo '{"rows": [{"at": "2026-10-26T00:00:00Z", "src": "slack", "key": "agent-rt0001", "usd": 1}]}' ;;
  teams) echo '{"teams": []}' ;;
  errors) echo '[{"sig": "s1", "message": "boom", "status": "open", "count": 2, "source": "bot", "kind": "x", "where": "w", "last": "2026-10-26T00:00:00Z", "keys": []}]' ;;
esac
SH
out="$(bash "$tmp/skills/fxa-ctl-dev/live-render.sh" '#errors/open' --probe 'await new Promise(r => setTimeout(r, 300)); return (ERRS ?? []).length' 2>&1)"; rc=$?
[ "$rc" = 3 ] && { echo "SKIP (no Chrome)"; exit 0; }
if [ "$(tail -1 <<< "$out")" = 1 ]; then echo "ok   the live errors list reaches the Errors view"; else echo "FAIL the live errors list reaches the Errors view: want [1] got [$(tail -1 <<< "$out")]"; exit 1; fi
# The manager's session records reach the local server, so a routine run reads as one.
out="$(bash "$tmp/skills/fxa-ctl-dev/live-render.sh" '#runners' --probe 'const j = await (await fetch("/api/runs/recent")).json(); return (j.runs ?? []).filter(r => r.routine).length' 2>&1)"
if [ "$(tail -1 <<< "$out")" = 1 ]; then echo "ok   a routine run's session record reaches the recent runs"; else echo "FAIL a routine run's session record reaches the recent runs: want [1] got [$(tail -1 <<< "$out")]"; exit 1; fi
# An admin's team route gets the team's admin data from the manager, for that team; a viewer's render asks for none.
q='const r = await fetch("/api/teams/crew/memory"); return r.ok ? ((await r.json()).entries ?? []).length : "none"'
a="$(bash "$tmp/skills/fxa-ctl-dev/live-render.sh" '#teams/crew/memory' --admin --probe "$q" 2>&1 | tail -1)|$(grep -c "lr-team.py 'crew'" "$tmp/skills/fxa-manager/team-calls" 2>/dev/null)"
rm -f "$tmp/skills/fxa-manager/team-calls"
v="$(bash "$tmp/skills/fxa-ctl-dev/live-render.sh" '#teams/crew/memory' --probe "$q" 2>&1 | tail -1)|$(cat "$tmp/skills/fxa-manager/team-calls" 2>/dev/null | wc -l | tr -d ' ')"
if [ "$a,$v" = "1|1,0|0" ]; then echo "ok   an admin's team route gets the team's memory, record and routines; a viewer's gets none"
else echo "FAIL an admin's team route gets the team's memory, record and routines; a viewer's gets none: want [1|1,0|0] got [$a,$v]"; exit 1; fi
