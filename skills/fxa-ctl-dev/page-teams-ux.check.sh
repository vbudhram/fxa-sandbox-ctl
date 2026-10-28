#!/usr/bin/env bash
# dashboard/index.html: the Teams side list counts teams only, and shows the same cost as the page (this month).
#   bash skills/fxa-ctl-dev/page-teams-ux.check.sh
set -u
here="$(dirname "$0")" p="$(dirname "$0")/page.sh"; fail=0
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
ck() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; fail=1; fi; }
# 30-day stats rows cost more than the team's month budget, so a 30-day figure in the side list shows.
now="$(date +%s)"
jq --argjson t "$now" '. + {"/api/stats": {rows: [{key: "agent-a1", src: "slack", profile: "fxa", t0: ($t - 3600), usd: 40}]}}' "$here/page-fixture-teams.json" > "$tmp/fx.json"
out="$(bash "$p" '#teams' --fixture "$tmp/fx.json" --probe 'await new Promise(r => setTimeout(r, 700)); const s = document.getElementById("side");
  return [s.querySelector(".sh .n")?.textContent.trim(), /\$12\.50 this month/.test(s.innerText), /\$40/.test(s.innerText)].join("|")')"; rc=$?
[ "$rc" = 3 ] && { echo "SKIP (no Chrome): the page probes did not run; set CHROME to run them"; exit 0; }
ck "the side header counts the teams, not the All teams row; the cost is this month's, as on the page" "2|true|false" "$out"
# FxA as a record (after the seed): its Settings edit like a record team's, with the runner keys read-only and no Delete.
jq '(."/api/teams".teams[] | select(.profile == "fxa") | .access) = {open: true, users: 0, listed: 0, channels: 0, jira: ["FXA"], record: true, status: "active"}' "$here/page-fixture-teams.json" > "$tmp/fxr.json"
out="$(PAGE_BUDGET=12000 bash "$p" '#teams/fxa/settings' --fixture "$tmp/fxr.json" --probe 'await new Promise(r => setTimeout(r, 1200)); const m = document.getElementById("main");
  return [!!m.querySelector("[data-tf=jira]"), !!m.querySelector("[data-tf=runner]"), !!m.querySelector("[data-tdel]"), !!m.querySelector("[data-tstatus=disabled]"), /The operator changes this with the CLI/.test(m.innerText)].join("|")')"
ck "FxA as a record: Jira has Change, the runner is read-only, and there is no Delete or Turn off" "true|false|false|false|true" "$out"
exit "$fail"
