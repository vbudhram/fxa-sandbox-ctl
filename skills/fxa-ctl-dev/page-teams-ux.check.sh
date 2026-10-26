#!/usr/bin/env bash
# dashboard/index.html: the Teams side list counts teams only.
#   bash skills/fxa-ctl-dev/page-teams-ux.check.sh
set -u
here="$(dirname "$0")" p="$(dirname "$0")/page.sh"; fail=0
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
ck() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; fail=1; fi; }
# A stats row, so the side list has its cost and last-used parts.
now="$(date +%s)"
jq --argjson t "$now" '. + {"/api/stats": {rows: [{key: "agent-a1", src: "slack", profile: "fxa", t0: ($t - 3600), usd: 40}]}}' "$here/page-fixture-teams.json" > "$tmp/fx.json"
out="$(bash "$p" '#teams' --fixture "$tmp/fx.json" --probe 'await new Promise(r => setTimeout(r, 700)); const s = document.getElementById("side");
  return s.querySelector(".sh .n")?.textContent.trim()')"; rc=$?
[ "$rc" = 3 ] && { echo "SKIP (no Chrome): the page probes did not run; set CHROME to run them"; exit 0; }
ck "the side header counts the teams, not the All teams row" "2" "$out"
exit "$fail"
