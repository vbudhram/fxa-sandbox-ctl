#!/usr/bin/env bash
# dashboard/index.html: the team Settings page shows how work reaches a team, in headless Chrome with stubbed writes.
#   bash skills/fxa-ctl-dev/page-team-inputs.check.sh
set -u
p="$(dirname "$0")/page.sh" F="$(dirname "$0")/page-fixture-teams.json"; fail=0
ck() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; fail=1; fi; }
G="$(mktemp)"; trap 'rm -f "$G"' EXIT
# fx <jq filter>: the teams fixture with Example active, then the filter applied, in $G.
fx() { jq '(."/api/teams/example".status) = "active" | (."/api/teams".teams[] | select(.profile == "example") | .access.status) = "active" | '"$1" "$F" > "$G"; }
stub='const w = ms => new Promise(r => setTimeout(r, ms)), sent = [], f0 = window.fetch;
  window.fetch = (u, o) => o?.method === "POST" ? (sent.push([u, JSON.parse(o.body)]), Promise.resolve(new Response(JSON.stringify({ ok: true, out: "ok" })))) : f0(u, o);
  const q = s => document.querySelector(s), main = () => document.getElementById("s-teams").innerText;'

fx '(."/api/teams/example".access) = {"open": false, "users": [], "channels": ["C0AAAA111"], "jira_prefixes": []} | (."/api/teams".teams[] | select(.profile == "example") | .access.channels) = 1'
who="$stub"' await w(700); const rec = o => ({ access: { open: false, users: [], channels: [], ...o } }), T = { profile: "x", access: { record: true } };
  return [teamWho(T, rec({ channels: ["C1"] })), teamWho({ profile: "x", access: { open: false, users: 0, listed: 0, channels: 2 } }), teamWho(T, rec({ users: ["U0AAA1111"], channels: ["C1"] })),
    /Nobody can start Example\./.test(document.querySelector(".thead").innerText)].join("|")'
out="$(bash "$p" '#teams/example/settings' --fixture "$G" --probe "$who")"; rc=$?
[ "$rc" = 3 ] && { echo "SKIP (no Chrome): the page probes did not run; set CHROME to run them"; exit 0; }
ck "a team with channels and no people reads Nobody: a channel lets nobody start it" "Nobody|Nobody|1 person|true" "$out"

# Each Jira setting has one home: the keys go with Slack, the launch cap with the queue. Each save keeps the other form's caps.
fx '(."/api/teams/example") += {"jira": {"project": "EXA", "queue": true}, "caps": {"usd_per_day": 5, "usd_per_month": 50, "launches_per_day": 7}} | (."/api/teams/example".access.jira_prefixes) = ["EXB"]'
keys="$stub"' try { await w(700); const open = async k => { q(`[data-tf="${k}"]`).click(); await w(400); }, save = async () => { q("[data-tf-save]").click(); await w(500); };
  const set = (sel, v) => { const e = q(sel); e.value = v; e.dispatchEvent(new Event("input", { bubbles: true })); }, form = () => q("[data-tf-save]").closest(".ckbody");
  await open("jira"); const jf = `${!!form().querySelector("#tf-launches_per_day")}:${!!form().querySelector("#tf-prefixes")}:${q("[data-tf-save]").textContent}`; set("#tf-launches_per_day", "9"); await save();
  await open("caps"); const cf = `${!!form().querySelector("#tf-launches_per_day")}`; set("#tf-usd_per_day", "6"); await save();
  await open("access"); const af = form().querySelector("#tf-prefixes")?.value; set("#tf-prefixes", "EXB, EXC"); await save();
  const b = i => sent.filter(x => /\/api\/teams\/example$/.test(x[0]))[i]?.[1] ?? {}, c = i => JSON.stringify(b(i).record?.caps);
  return [jf, c(0), b(0).record?.access?.jira_prefixes?.join(","), cf, c(1), af, b(2).record?.access?.jira_prefixes?.join(","), [0, 1, 2].map(i => b(i).generation).join(",")].join("|") } catch (e) { return "ERR " + e.message + " after " + sent.length + " posts"; }'
ck "Jira keys move to the Slack form and the launch cap to the Jira form; each save keeps the other caps and sends the loaded generation" \
  'true:false:Save|{"usd_per_day":5,"usd_per_month":50,"launches_per_day":9}|EXB|false|{"usd_per_day":6,"usd_per_month":50,"launches_per_day":7}|EXB|EXB,EXC|1792640520000000,1792640520000000,1792640520000000' \
  "$(PAGE_BUDGET=12000 bash "$p" '#teams/example/settings' --fixture "$G" --probe "$keys")"

[ "$fail" = 0 ] && echo "all checks pass"
exit "$fail"
