#!/usr/bin/env bash
# dashboard/index.html: the Memory tab of a team lists the team's facts for an admin, and says why when it cannot.
#   bash skills/fxa-ctl-dev/page-team-memory.check.sh
set -u
here="$(dirname "$0")" p="$(dirname "$0")/page.sh"; fail=0
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
ck() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; fail=1; fi; }
# The teams fixture with a memory answer: one fact a person wrote with untrusted text, one old fact.
fx() { jq --argjson m "$1" --argjson a "${2:-true}" '(."/api/teams".teams[] | select(.profile == "example") | .access.status) = "active" | . + {"/api/teams/example/memory": $m, "/api/team-admin": {admin: $a}}' "$here/page-fixture-teams.json" > "$tmp/$3.json"; }
fx '{"on":true,"entries":[{"id":"mem-0000aaaa","kind":"trap","file":"trap.md","text":"<img src=x onerror=alert(1)> breaks","why":"it broke twice","path":"","terms":"","cites":[{"cite":"mozilla/fxa:a.js:3","anchor":"a"}],"confirmed":"2099-01-01","source":"dashboard -","taint":false,"person":true,"v":"abc"},{"id":"mem-0000bbbb","kind":"system","file":"system.md","text":"Old fact","why":"","path":"","terms":"","cites":[{"cite":"mozilla/fxa:b.js:1","anchor":"b"},{"cite":"mozilla/other:c.py:2","anchor":"c"}],"confirmed":"2020-01-01","source":"r1 -","taint":true,"person":false,"v":"def"}]}' true list
fx '{"on":false,"entries":[]}' true off
fx '{"on":true,"entries":[]}' true empty
fx '{"on":true,"entries":[]}' false viewer
w='await new Promise(r => setTimeout(r, 700)); const m = document.getElementById("s-teams");'
out="$(bash "$p" '#teams/example/memory' --fixture "$tmp/list.json" --probe "$w"' const rows = [...m.querySelectorAll("tr[data-mem]")];
  return [document.querySelector(".ttab[aria-current]")?.textContent, rows.length, !!m.querySelector("img"), /<img src=x/.test(rows[0].textContent),
    rows[0].querySelector(".mtags").textContent, rows[1].querySelector(".mtags").textContent, rows[1].querySelectorAll(".mono").length].join("|")')"; rc=$?
[ "$rc" = 3 ] && { echo "SKIP (no Chrome): the page probes did not run; set CHROME to run them"; exit 0; }
ck "an admin sees the Memory tab with one row a fact, untrusted text as text, and its tags" "Memory|2|false|true|person|not in indextainted run|2" "$out"
st="$w"' return m.querySelector(".tcard, .emptybox")?.textContent.trim()'
ck "memory off on the host says so" "Team memory is off on this host." "$(bash "$p" '#teams/example/memory' --fixture "$tmp/off.json" --probe "$st")"
ck "a team with no facts says how they arrive" "No team memory yet. A run adds a fact when its cites hold on main." "$(bash "$p" '#teams/example/memory' --fixture "$tmp/empty.json" --probe "$st")"
ck "a viewer who is not an admin gets the admin line, and no request for the memory" "Only a team admin can see and change team memory.|0" \
  "$(bash "$p" '#teams/example/memory' --fixture "$tmp/viewer.json" --probe "$w"' return m.querySelector(".tcard").textContent.trim() + "|" + performance.getEntriesByType("resource").filter(e => /\/memory$/.test(e.name)).length')"
ck "a draft team has no Memory tab, and its link opens Settings" "Settings1 left|false" \
  "$(bash "$p" '#teams/example/memory' --fixture "$here/page-fixture-teams.json" --probe "$w"' return document.querySelector(".ttab[aria-current]")?.textContent + "|" + [...document.querySelectorAll(".ttab")].some(a => /Memory/.test(a.textContent))')"
exit "$fail"
