#!/usr/bin/env bash
# dashboard/index.html: the Memory tab of a team lists the team's facts for an admin, and says why when it cannot.
#   bash skills/fxa-ctl-dev/page-team-memory.check.sh
set -u
here="$(dirname "$0")" p="$(dirname "$0")/page.sh"; fail=0
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
ck() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; fail=1; fi; }
# The teams fixture with a memory answer: one fact a person wrote with untrusted text, one old fact.
fx() { jq --argjson m "$1" --argjson a "${2:-true}" '(."/api/teams".teams[] | select(.profile == "example") | .access.status) = "active" | . + {"/api/teams/example/memory": $m, "/api/team-admin": {admin: $a}}' "$here/page-fixture-teams.json" > "$tmp/$3.json"; }
fx '{"on":true,"entries":[{"id":"mem-0000aaaa","scope":"team","kind":"trap","file":"trap.md","text":"<img src=x onerror=alert(1)> breaks","why":"it broke twice","path":"","terms":"","cites":[{"cite":"mozilla/fxa:a.js:3","anchor":"a"}],"confirmed":"2099-01-01","source":"dashboard -","taint":false,"person":true,"v":"abc"},{"id":"mem-0000bbbb","scope":"team","kind":"system","file":"system.md","text":"Old fact","why":"","path":"","terms":"","cites":[{"cite":"mozilla/fxa:b.js:1","anchor":"b"},{"cite":"mozilla/other:c.py:2","anchor":"c"}],"confirmed":"2020-01-01","source":"r1 -","taint":true,"person":false,"v":"def"}]}' true list
fx '{"on":false,"entries":[]}' true off
fx '{"on":true,"entries":[]}' true empty
fx '{"on":true,"entries":[]}' false viewer
w='await new Promise(r => setTimeout(r, 700)); const m = document.getElementById("s-teams");'
out="$(bash "$p" '#teams/example/memory' --fixture "$tmp/list.json" --probe "$w"' const rows = [...m.querySelectorAll("tr[data-mem]")];
  return [document.querySelector(".ttab[aria-current]")?.textContent, rows.length, !!m.querySelector("img"), /<img src=x/.test(rows[0].textContent),
    rows[0].querySelector(".mtags").textContent, rows[1].querySelector(".mtags").textContent, rows[1].querySelectorAll(".mono").length].join("|")')"; rc=$?
[ "$rc" = 3 ] && { echo "SKIP (no Chrome): the page probes did not run; set CHROME to run them"; exit 0; }
ck "an admin sees the Memory tab with one row a fact, untrusted text as text, and its tags" "Memory|2|false|true|person|not in indextainted run|2" "$out"
# Add, a field error, an edit with its version, and a delete that needs a second click; the POSTs are stubbed.
flow="$w"' const sent = [], f0 = window.fetch, q = s => document.querySelector(s), tick = () => new Promise(r => setTimeout(r, 150));
  let next = { status: 400, body: { error: "cite1: write it as owner/repo:path:line" } };
  window.fetch = (u, o) => o?.method === "POST" ? (sent.push([u.replace(/^.*\/api/, "/api"), JSON.parse(o.body)]), Promise.resolve(new Response(JSON.stringify(next.body), { status: next.status }))) : f0(u, o);
  q("[data-mem-new]").click(); await tick(); const t = q("#mem-text"); t.value = "A fact"; t.dispatchEvent(new Event("input", { bubbles: true }));
  q("[data-mem-save]").click(); await tick();
  const err = [q("#mem-cite1").getAttribute("aria-invalid"), document.activeElement?.id, !!q("[data-mem-form]")].join(",");
  next = { status: 200, body: { out: "set mem-0000cccc" } }; q("[data-mem-save]").click(); await tick();
  q("[data-mem-edit=\"mem-0000aaaa\"]").click(); await tick(); q("[data-mem-save]").click(); await tick();
  q("[data-mem-del=\"mem-0000bbbb\"]").click(); await tick(); const armed = q("[data-mem-del=\"mem-0000bbbb\"]").textContent;
  next = { status: 200, body: { out: "delete mem-0000bbbb" } }; q("[data-mem-del=\"mem-0000bbbb\"]").click(); await tick();
  return [err, sent.length, sent[0][0], sent[0][1].entry.text, sent[1][0], sent[2][0], sent[2][1].v, armed, sent[3][0], sent[3][1].v + "/" + sent[3][1].scope].join("|")'
ck "add shows a field error with focus, then saves; edit posts its version; delete needs a second click" \
  "true,mem-cite1,true|4|/api/teams/example/memory|A fact|/api/teams/example/memory|/api/teams/example/memory/mem-0000aaaa|abc|Delete it?|/api/teams/example/memory/mem-0000bbbb/delete|def/team" \
  "$(bash "$p" '#teams/example/memory' --fixture "$tmp/list.json" --probe "$flow")"
ck "a filter narrows the rows and keeps the focus in the box" "1|true" \
  "$(bash "$p" '#teams/example/memory' --fixture "$tmp/list.json" --probe "$w"' const i = m.querySelector("[data-mem-q]"); i.focus(); i.value = "old"; i.dispatchEvent(new Event("input", { bubbles: true })); await new Promise(r => setTimeout(r, 100)); return m.querySelectorAll("tr[data-mem]").length + "|" + document.activeElement.matches("[data-mem-q]")')"
st="$w"' return m.querySelector(".tcard, .emptybox")?.textContent.trim()'
ck "memory off on the host says so" "Team memory is off on this host." "$(bash "$p" '#teams/example/memory' --fixture "$tmp/off.json" --probe "$st")"
ck "a team with no facts says how they arrive" "No team memory yet. A run adds a fact when its cites hold on main, or add one here." "$(bash "$p" '#teams/example/memory' --fixture "$tmp/empty.json" --probe "$w"' return m.querySelector(".emptybox")?.textContent.trim()')"
ck "a viewer who is not an admin gets the admin line, and no request for the memory" "Only a team admin can see and change team memory.|0" \
  "$(bash "$p" '#teams/example/memory' --fixture "$tmp/viewer.json" --probe "$w"' return m.querySelector(".tcard").textContent.trim() + "|" + performance.getEntriesByType("resource").filter(e => /\/memory$/.test(e.name)).length')"
ck "a draft team has no Memory tab, and its link opens Settings" "Settings1 left|false" \
  "$(bash "$p" '#teams/example/memory' --fixture "$here/page-fixture-teams.json" --probe "$w"' return document.querySelector(".ttab[aria-current]")?.textContent + "|" + [...document.querySelectorAll(".ttab")].some(a => /Memory/.test(a.textContent))')"
exit "$fail"
