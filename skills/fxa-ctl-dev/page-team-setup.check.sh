#!/usr/bin/env bash
# dashboard/index.html: a new team in three fields, and Test and activate, in headless Chrome with stubbed writes.
#   bash skills/fxa-ctl-dev/page-team-setup.check.sh
set -u
p="$(dirname "$0")/page.sh" F="$(dirname "$0")/page-fixture-teams.json"; fail=0
ck() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; fail=1; fi; }
# Each probe stubs the writes: a POST is recorded and answers ok; GET .../test answers what the probe sets.
stub='const w = ms => new Promise(r => setTimeout(r, ms)), sent = [], f0 = window.fetch; let test = null;
  window.fetch = (u, o) => o?.method === "POST" ? (sent.push([u, JSON.parse(o.body)]), Promise.resolve(new Response(JSON.stringify({ ok: true, out: "ok" }), { status: u.endsWith("/test") ? 202 : 200 })))
    : test && u.endsWith("/test") ? Promise.resolve(new Response(JSON.stringify(test))) : f0(u, o);'
new="$stub"' await w(600); const set = (id, v) => { const e = document.getElementById(id); e.value = v; e.dispatchEvent(new Event("input", { bubbles: true })); };
  set("nt-name", "relay"); set("nt-repo", "mozilla/fx-private-relay"); set("nt-goal", "Relay work.");
  document.querySelector("[data-nt-create]").click(); await w(300); const before = `${sent.length}|${/Pick a stack/.test(document.getElementById("s-teams").innerText)}`;
  document.querySelector("[data-nt=stack][value=none]").click(); const rb = document.querySelector("[data-nt-readback]").textContent;
  document.querySelector("[data-nt-create]").click(); await w(500); const r = sent[0]?.[1]?.record ?? {};
  return [before, /Creates Relay as a draft, on mozilla\/fx-private-relay, with no FxA stack/.test(rb), sent[0]?.[0], r.label, r.stack?.kind, r.access?.open, location.hash].join("|")'
out="$(bash "$p" '#teams/new' --fixture "$F" --probe "$new")"; rc=$?
[ "$rc" = 3 ] && { echo "SKIP (no Chrome): the page probes did not run; set CHROME to run them"; exit 0; }
ck "new team: a missing stack is marked before any POST; then Create draft posts the record and opens its Settings" \
  "0|true|true|/api/teams|Relay|none|true|#teams/relay/settings" "$out"
act="$stub"' await w(900); const h = document.getElementById("s-teams").innerText, box = document.querySelector("[data-ttest-act]")?.checked;
  document.querySelector("[data-ttest]").click(); await w(300);
  test = { result: "passed", at: 1, generation: 1792640520000000, tested: 1792640520000000, started_at: 1, lines: ["passed: team example may be activated at generation 1792640520000000"] };
  await teamTestPoll("example"); await w(300);
  return [/Settings\s*1 left/.test(h), !/Overview/.test(document.querySelector(".ttabs").innerText), box, sent.map(s => s[0] + (s[1].status ? ":" + s[1].status : "")).join(",")].join("|")'
ck "a draft opens on Settings with one step left; Test and activate tests, then activates on the pass" \
  "true|true|true|/api/teams/example/test,/api/teams/example/status:active" "$(bash "$p" '#teams/example' --fixture "$F" --probe "$act")"
[ "$fail" = 0 ] && echo "all checks pass"
exit "$fail"
