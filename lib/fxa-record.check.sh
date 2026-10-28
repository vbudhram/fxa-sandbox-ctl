#!/usr/bin/env bash
# Offline check for FxA as a team record (lib/pipeline.sh, profile env): behind FXA_FXA_RECORD=1 the
# record loads with FxA's old host names, and profile env shows the same values as the conf, except
# the keys that may differ. The conf still wins while the switch is off.
#   bash lib/fxa-record.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
root="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
T="$tmp/teams"; mkdir -p "$T" "$tmp/home"; cp "$root/lib/testdata/fxa-team.json" "$T/fxa.json"
# profile env, as a host with the conf and a cached fxa record: <switch> [<pipeline>]
penv() { ( cd "$root" && env HOME="$tmp/home" FXA_TEAMS_DIR="$T" FXA_DB="$tmp/fxa.db" FXA_GCE_PROJECT=p1 FXA_VM_BACKEND=tart \
  FXA_FXA_RECORD="$1" ./fxa-sandbox-ctl ${2:+--pipeline "$2"} profile env 2>&1 ); }
get() { sed -n "s/^$1=//p" | tr -d '"'; }
# The keys a parity diff may show (the record is explicit where the conf left a default), and the
# keys the conf sets to a value the reader's default already has. The repo rows and the stack dir
# must be equal: only the GCE image has /home/agent/fxa, and a tart runner has only /workspace.
allowed="PIPE_MCP PIPE_EGRESS_EXTRA PIPE_PR_OPEN PIPE_JIRA_PROJECT
PIPE_VM_BACKEND PIPE_AGENT_RUNTIME PIPE_JIRA_DONE_STATUS PIPE_JIRA_SPRINT_FIELD PIPE_MAX_LAUNCHES_TART"
for p in fxa-ai-fixme fxa ""; do
  d="$(diff <(penv 0 "$p") <(penv 1 "$p") | sed -n 's/^[<>] \([A-Za-z_]*\)=.*/\1/p' | sort -u | grep -vxF "$(printf '%s\n' $allowed)" || true)"
  check "the parity diff for --pipeline ${p:-(none)} shows only the allowed keys" "" "$(echo $d)"
done
on="$(penv 1 fxa-ai-fixme)"; off="$(penv 0 fxa-ai-fixme)"
check "with the switch on, the record loads under the old name, state dir and URIs" \
  "fxa-ai-fixme|fxa|$tmp/home/.claude/state/fxa-ai-fixme|gs://p1-fxa-ai-fixme/fxa-ai-fixme/PAUSED|gs://p1-fxa-ai-fixme/fxa-ai-fixme/state|gce" \
  "$(get PIPE_NAME <<< "$on")|$(get PIPE_PROFILE <<< "$on")|$(get PIPE_STATE_DIR <<< "$on")|$(get PIPE_PAUSE_URI <<< "$on")|$(get PIPE_STATE_URI <<< "$on")|$(get PIPE_VM_BACKEND <<< "$on")"
check "the queue JQL is byte-equal, and the timer is still fxa-pass.timer" "same|fxa-pass.timer" \
  "$([ -n "$(get queue_jql <<< "$on")" ] && [ "$(get queue_jql <<< "$on")" = "$(get queue_jql <<< "$off")" ] && echo same || echo differs)|$(get timer_unit <<< "$on")"
check "with the switch unset, the conf still wins over a cached record" "tart|" \
  "$(penv "" fxa | get PIPE_VM_BACKEND)|$(penv "" fxa | get PIPE_MCP)"
check "a blank PIPE_PAUSE_URI stays blank with the switch on" "" \
  "$( (cd "$root" && env HOME="$tmp/home" FXA_TEAMS_DIR="$T" FXA_DB="$tmp/fxa.db" FXA_GCE_PROJECT=p1 FXA_VM_BACKEND=tart FXA_FXA_RECORD=1 PIPE_PAUSE_URI= ./fxa-sandbox-ctl profile env 2>&1) | get PIPE_PAUSE_URI)"
check "a secret prints only set or unset" "PIPE_JIRA_BASIC=set|0" \
  "$( (cd "$root" && env HOME="$tmp/home" FXA_TEAMS_DIR="$T" FXA_DB="$tmp/fxa.db" FXA_VM_BACKEND=tart FXA_FXA_RECORD=1 PIPE_JIRA_BASIC=bot@example.com:tok-q7 ./fxa-sandbox-ctl profile env 2>&1) > "$tmp/sec"; grep '^PIPE_JIRA_BASIC=' "$tmp/sec")|$(grep -c 'tok-q7' "$tmp/sec")"
mkdir -p "$tmp/empty"
nocache() { ( cd "$root" && env HOME="$tmp/home" FXA_TEAMS_DIR="$tmp/empty" FXA_DB="$tmp/fxa.db" FXA_GCE_PROJECT= FXA_VM_BACKEND=tart FXA_FXA_RECORD=1 ./fxa-sandbox-ctl "$@" 2>&1; echo "rc=$?" ); }
out="$(nocache profile env)"
check "with the switch on and no cached record, the load stops and names profile sync" "1|rc=1" \
  "$(grep -c "ERROR: no FxA team record in $tmp/empty; run fxa-sandbox-ctl profile sync" <<< "$out")|$(tail -1 <<< "$out")"
check "profile sync still runs on that host, so the error can be fixed" "rc=0" "$(nocache profile sync | tail -1)"

[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
