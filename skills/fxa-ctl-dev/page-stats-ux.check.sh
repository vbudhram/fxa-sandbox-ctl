#!/usr/bin/env bash
# Stats names people by their session's owner and labels kinds and stop reasons in words (dashboard/index.html).
#   bash skills/fxa-ctl-dev/page-stats-ux.check.sh
set -u
here="$(dirname "$0")"
out="$(bash "$here/page.sh" '#stats/spend' --fixture "$here/page-fixture-overview.json" --width 1280 --probe '
  await new Promise(r => setTimeout(r, 400)); const ok = (c, m) => (c ? "ok   " : "FAIL ") + m;
  AGENTS = AGENTS || { sessions: [] }; AGENTS.sessions = AGENTS.sessions || [];
  AGENTS.sessions.push({ key: "agent-ux0001", owner: "U1", owner_name: "Pat Doe", state: "stopped" }, { key: "agent-ux0002", routine_run: 3, routine_name: "Code review", owner: "routine:x/3", state: "stopped" });
  return [ok(statPerson({ src: "slack", key: "agent-ux0001", who: null }) === "Pat Doe", "a row with no who is named by its session owner"),
    ok(statPerson({ src: "slack", key: "agent-ux0002", who: null }) === null, "a routine run is not a person"),
    ok(statPerson({ src: "slack", key: "agent-gone01", who: null }) === "name not recorded", "a row with no session and no who says so"),
    ok(["pass", "triage", "session", "answered", "upgraded"].every(k => /^[A-Z]/.test(KIND[k] ?? "")), "every kind has a capitalized label"),
    ok(STOP_WHY.inactive && STOP_WHY.idle && STOP_WHY.inactive !== STOP_WHY.idle, "inactive and idle stops read differently")].join("\n");')"; rc=$?
[ "$rc" = 3 ] && { echo "SKIP (no Chrome)"; exit 0; }
printf '%s\n' "$out"; [ "$(grep -c '^ok' <<< "$out")" = 5 ] || exit 1
