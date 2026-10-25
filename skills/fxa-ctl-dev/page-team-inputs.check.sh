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

[ "$fail" = 0 ] && echo "all checks pass"
exit "$fail"
