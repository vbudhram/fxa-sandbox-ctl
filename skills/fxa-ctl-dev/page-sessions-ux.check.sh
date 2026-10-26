#!/usr/bin/env bash
# Sessions rows name a routine run by its routine, and an empty list is a plain note, not a group heading (dashboard/index.html).
#   bash skills/fxa-ctl-dev/page-sessions-ux.check.sh
set -u
here="$(dirname "$0")"
out="$(bash "$here/page.sh" '#sessions/stopped' --fixture "$here/page-fixture.json" --width 1280 --probe '
  const ok = (c, m) => (c ? "ok   " : "FAIL ") + m;
  const run = { key: "agent-rt0001", state: "stopped", profile: "fxa", routine_run: 7, routine_name: "Code review",
    request: "This run was started on a schedule by the routine \"Code review\" of team fxa. Nobody reads this conversation." };
  const fix = { key: "agent-rt0002", state: "stopped", profile: "fxa", request: "Ask: why does it fail?" };
  return [ok(convTitle(run) === "Code review run", "a routine run is titled by its routine, not the schedule preamble: " + convTitle(run)),
    ok(convTitle(fix) === "Ask: why does it fail?", "a Slack session keeps its request as the title")].join("\n");')"; rc=$?
[ "$rc" = 3 ] && { echo "SKIP (no Chrome)"; exit 0; }
printf '%s\n' "$out"; grep -q '^FAIL' <<< "$out" && exit 1; exit 0
