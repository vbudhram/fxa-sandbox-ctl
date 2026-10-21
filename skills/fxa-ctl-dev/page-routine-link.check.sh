#!/usr/bin/env bash
# dashboard/index.html: a link #teams/<team>/routines/<id> opens that routine's page; with no id, the list opens.
#   bash skills/fxa-ctl-dev/page-routine-link.check.sh
set -u
p="$(dirname "$0")/page.sh" F="$(dirname "$0")/page-fixture-routines.json"; fail=0
ck() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; fail=1; fi; }
probe='await new Promise(r => setTimeout(r, 600)); const c = document.querySelector(".rtd .nm"); return c ? c.textContent.trim().split(" ")[0] : document.querySelector("[data-routine-list]") ? "list" : "none"'
out="$(bash "$p" '#teams/example/routines/1' --fixture "$F" --probe "$probe")"; rc=$?
[ "$rc" = 3 ] && { echo "SKIP (no Chrome): the page probes did not run; set CHROME to run them"; exit 0; }
ck "a link with routine 1 opens the page of Alpha" "Alpha" "$out"
ck "with no routine in the link, the list opens" "list" "$(bash "$p" '#teams/example/routines' --fixture "$F" --probe "$probe")"
gone='await new Promise(r => setTimeout(r, 600)); return /The routine from the link is no longer here/.test(document.querySelector("[data-routine-list]")?.textContent ?? "")'
ck "a link to a routine that is gone says so above the list" "true" "$(bash "$p" '#teams/example/routines/999' --fixture "$F" --probe "$gone")"
# A link to a team already open selects the routine at once, and leaves no id for the next team's tab.
want='await new Promise(r => setTimeout(r, 600)); location.hash = "#teams/example/routines/1"; await new Promise(r => setTimeout(r, 400)); return `${RT.sel}|${RT_WANT}`'
ck "a link to an open team selects its routine and keeps no id for another team" "1|0" "$(bash "$p" '#teams/example/routines' --fixture "$F" --probe "$want")"
# A card's link opens its page, and the back link goes to the list, also when the hash does not change.
nav='await new Promise(r => setTimeout(r, 600)); document.querySelector("[data-rt-sel=\"2\"]").click(); await new Promise(r => setTimeout(r, 300)); const a = document.querySelector(".rtd .nm")?.textContent.trim().split(" ")[0];
  document.querySelector("[data-rt-list]").click(); await new Promise(r => setTimeout(r, 300)); return `${a}|${!!document.querySelector("[data-routine-list]")}`'
ck "a card opens its routine, and Routines goes back to the list" "Beta|true" "$(bash "$p" '#teams/example/routines' --fixture "$F" --probe "$nav")"
# The create flow: a start fills the draft, the schedule buttons and the name update the read-back, and Create posts
# that routine; Create and run now also posts its run.
flow='const w = ms => new Promise(r => setTimeout(r, ms)); await w(600); const sent = [], f0 = window.fetch;
  window.fetch = (u, o) => o?.method === "POST" ? (sent.push([u, JSON.parse(o.body)]), Promise.resolve(new Response(JSON.stringify({ out: "created routine 7" }), { status: 200 }))) : f0(u, o);
  document.querySelector("[data-rt-new]").click(); await w(200); document.querySelector("[data-rt-tpl=\"code-review\"]").click(); await w(200);
  document.querySelector("[data-rt-kind=\"weekly\"]").click(); await w(200); document.querySelector("[data-rt-day=\"fri\"]").click(); await w(200);
  const n = document.getElementById("rt-name"); n.value = "Friday review"; n.dispatchEvent(new Event("input", { bubbles: true }));
  const rb = document.querySelector("[data-rt-readback]").textContent, then = THEN;
  document.querySelector(then ? "[data-rt-then=\"run\"]" : "[data-rt-save]").click(); await w(500);
  return [/^Friday review runs every Friday at 09:00 /.test(rb), ...sent.map(s => `${s[0]} ${s[1].routine ? `${s[1].routine.template} ${s[1].routine.schedule} ${s[1].routine.repos}` : ""}`.trim())].join("|")'
ck "Create posts the draft the start and the buttons made" "true|/api/teams/example/routines code-review weekly fri 09:00 example/app" "$(bash "$p" '#teams/example/routines' --fixture "$F" --probe "${flow/THEN/false}")"
ck "Create and run now posts the routine, then its run" "true|/api/teams/example/routines code-review weekly fri 09:00 example/app|/api/teams/example/routines/7/run" "$(bash "$p" '#teams/example/routines' --fixture "$F" --probe "${flow/THEN/true}")"
[ "$fail" = 0 ] && echo "all checks pass"
exit "$fail"
