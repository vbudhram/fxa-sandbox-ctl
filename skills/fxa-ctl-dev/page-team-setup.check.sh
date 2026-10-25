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
# The probe waits 1.5 s plus a test poll after the 2.5 s start: the default 6 s budget left no room on a busy host, and the answer came back empty (i585).
ck "a draft opens on Settings with one step left; Test and activate tests, then activates on the pass" \
  "true|true|true|/api/teams/example/test,/api/teams/example/status:active" "$(PAGE_BUDGET=12000 bash "$p" '#teams/example' --fixture "$F" --probe "$act")"
# The settings items beyond the first seven: options-driven pickers, the people search, and the record each Save posts.
G="$(mktemp)"; trap 'rm -f "$G"' EXIT
jq '. + {"/api/teams/options": {"caps": {"usd_per_day": 50, "usd_per_month": 900, "launches_per_day": 9}, "skills": ["fxa-stack", "fxa-verify"], "connectors": ["jira", "sentry"], "boot": [{"script": "web", "sha256": "'"$(printf 'b%.0s' $(seq 64))"'"}], "egress_deny": ["pastebin.com"]},
  "/api/teams/people/pat": {"at": 7, "people": [{"id": "U0PAT0001", "name": "Pat Doe", "handle": "pat", "email": "pat@example.com"}]}, "/api/teams/people/U0AAA1111": {"at": 7, "people": []}}
  | (."/api/teams/example".access) = {"open": false, "users": [], "channels": []}' "$F" > "$G"
items="$stub"' try { await w(700); const q = s => document.querySelector(s), open = async k => { q(`[data-tf="${k}"]`).click(); await w(400); }, save = async () => { q("[data-tf-save]").click(); await w(400); };
  const set = (sel, v) => { const e = q(sel); e.value = v; e.dispatchEvent(new Event("input", { bubbles: true })); }, tick = sel => { const e = q(sel); e.checked = !e.checked; e.dispatchEvent(new Event("input", { bubbles: true })); };
  await open("skills"); const sk = document.querySelectorAll("[data-tfset=skills]").length; tick("[data-tfset=skills][data-v=fxa-verify]"); await save();
  await open("caps"); const cap = /at most 50/.test(q("[data-tform]").textContent); q("[data-tf-cancel]").click(); await w(200);
  await open("boot"); set("#tf-script", "web"); await save();
  await open("secrets"); set("#tf-jira", "login"); await save();
  await open("access"); q("[data-tfpq=users]").focus(); set("[data-tfpq=users]", "pat"); await w(700); const found = q("[data-tfpick=users]")?.dataset.id, focus = document.activeElement?.dataset?.tfpq;
  q("[data-tfpick=users]").click(); await w(300); const chip = !!q("[data-tfunpick=users][data-id=U0PAT0001]"); await save();
  const rec = i => sent.filter(x => /\/api\/teams\/example$/.test(x[0]))[i]?.[1]?.record ?? {};
  return [sk, rec(0).skills?.join(","), cap, rec(1).boot?.script + ":" + rec(1).boot?.sha256?.length, rec(2).secrets?.jira, found, focus, chip, rec(3).access?.users?.join(",")].join("|") } catch (e) { return "ERR " + e.message + " after " + sent.length + " posts"; }'
ck "settings: skills, caps, boot and secrets forms post their keys; the people search adds a person" \
  "2|fxa-verify|true|web:64|fxa-team-example--login|U0PAT0001|users|true|U0PAT0001" "$(PAGE_BUDGET=15000 bash "$p" '#teams/example/settings' --fixture "$G" --probe "$items")"
[ "$fail" = 0 ] && echo "all checks pass"
exit "$fail"
