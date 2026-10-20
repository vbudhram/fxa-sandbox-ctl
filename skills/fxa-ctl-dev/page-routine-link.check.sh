#!/usr/bin/env bash
# dashboard/index.html: a Slack History link #teams/<team>/routines/<id> opens that routine, not the one that ran last.
#   bash skills/fxa-ctl-dev/page-routine-link.check.sh
set -u
p="$(dirname "$0")/page.sh" F="$(dirname "$0")/page-fixture-routines.json"; fail=0
ck() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; fail=1; fi; }
probe='await new Promise(r => setTimeout(r, 600)); const c = document.querySelector(".tcard"); return c ? (/Alpha/.test(c.textContent) ? "Alpha" : /Beta/.test(c.textContent) ? "Beta" : "?") : "none"'
out="$(bash "$p" '#teams/example/routines/1' --fixture "$F" --probe "$probe")"; rc=$?
[ "$rc" = 3 ] && { echo "SKIP (no Chrome): the page probes did not run; set CHROME to run them"; exit 0; }
ck "a link with routine 1 opens Alpha, the routine that ran first" "Alpha" "$out"
ck "with no routine in the link, the routine that ran last (Beta) opens" "Beta" "$(bash "$p" '#teams/example/routines' --fixture "$F" --probe "$probe")"
gone='await new Promise(r => setTimeout(r, 600)); return /The routine from the link is no longer here/.test(document.querySelector("[data-routine-list]")?.textContent ?? "")'
ck "a link to a routine that is gone says so above the one that ran last" "true" "$(bash "$p" '#teams/example/routines/999' --fixture "$F" --probe "$gone")"
# A link to a team already open selects the routine at once, and leaves no id for the next team's tab.
want='await new Promise(r => setTimeout(r, 600)); location.hash = "#teams/example/routines/1"; await new Promise(r => setTimeout(r, 400)); return `${RT.sel}|${RT_WANT}`'
ck "a link to an open team selects its routine and keeps no id for another team" "1|0" "$(bash "$p" '#teams/example/routines' --fixture "$F" --probe "$want")"
[ "$fail" = 0 ] && echo "all checks pass"
exit "$fail"
