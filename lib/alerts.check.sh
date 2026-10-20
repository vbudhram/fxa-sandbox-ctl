#!/usr/bin/env bash
# Offline check for the alerts: raise once on a breach, resolve when it clears, raise again after.
#   bash lib/alerts.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
here="$(cd "$(dirname "$0")" && pwd)"
export FXA_ERRORS_FILE="$tmp/errors.jsonl" FXA_ERRORS_URI="" FXA_LLM_PROXY_DIR="$tmp/proxy"
SESSION_DIR="$tmp/s"; mkdir -p "$SESSION_DIR" "$tmp/proxy"
source "$here/config.sh" >/dev/null 2>&1; source "$here/errors.sh"; source "$here/alerts.sh"
FXA_SESSION_DIR="$SESSION_DIR" source "$here/session.sh"  # _session_records: the alerts read sessions through it
now=$(date +%s)
# 7 h idle in a session stopped an hour ago; three boots with a median of 90 s; $130 of spend.
echo "{\"key\":\"agent-al01\",\"stopped_at\":\"$(( now - 3600 ))\",\"idle_s\":\"25200\",\"booted_at\":\"$(( now - 9000 ))\",\"boot_s\":\"90\"}" > "$SESSION_DIR/agent-al01.json"
echo "{\"key\":\"agent-al02\",\"booted_at\":\"$(( now - 600 ))\",\"boot_s\":\"95\",\"boot_steps\":[{\"step\":\"starting a runner\",\"s\":44},{\"step\":\"locking down\",\"s\":20}]}" > "$SESSION_DIR/agent-al02.json"
echo "{\"key\":\"agent-al03\",\"booted_at\":\"$(( now - 600 ))\",\"boot_s\":\"12\"}" > "$SESSION_DIR/agent-al03.json"
echo "{\"at\":\"$(date -u +%FT%TZ)\",\"usd\":130}" > "$tmp/proxy/usage.jsonl"
out="$(alerts_check)"
check "idle, spend and slow boot raise; capacity does not" "1|1|1|0" \
  "$(grep -c '^alert: idle runner' <<< "$out")|$(grep -c '^alert: LLM spend' <<< "$out")|$(grep -c '^alert: the median boot' <<< "$out")|$(grep -c 'capacity' <<< "$out")"
check "the slow-boot alert names the step the slow boots spent most time in" "1" "$(grep -c "spend most time in starting a runner (44 s each)" <<< "$out")"
check "a breach that lasts is not raised again" "" "$(alerts_check)"
rm "$tmp/proxy/usage.jsonl"
check "spend under the threshold again: resolved" "cleared: daily_spend" "$(alerts_check)"
echo "{\"at\":\"$(date -u +%FT%TZ)\",\"usd\":200}" > "$tmp/proxy/usage.jsonl"; sleep 1
check "a new breach raises again, so the operator gets a DM" "1" "$(alerts_check | grep -c '^alert: LLM spend')"
check "alerts_maybe runs at most once an hour" "" "$(touch "$SESSION_DIR/.alerts-at"; alerts_maybe)"
# The Firecracker snapshot: a failed refresh and an old snapshot, read from the status
# file that fc_status keeps while the host is off.
rm -f "$SESSION_DIR/.alerts-at"
printf 'refresh=exit-code\nmade=%s\n' "$(( now - 5 * 86400 ))" > "$SESSION_DIR/.fc-status"
out="$(alerts_check)"
check "a failed refresh and a 5-day-old snapshot raise" "1|1" \
  "$(grep -c '^alert: the Firecracker snapshot refresh failed' <<< "$out")|$(grep -c '^alert: the Firecracker snapshot has had no good refresh for 5 days' <<< "$out")"
printf 'refresh=success\nmade=%s\n' "$now" > "$SESSION_DIR/.fc-status"
out="$(alerts_check)"
check "a good refresh clears both" "1|1" "$(grep -c '^cleared: snapshot_refresh' <<< "$out")|$(grep -c '^cleared: snapshot_age' <<< "$out")"
# A snapshot made long ago with a good refresh since (main did not move) is not stale.
rm -f "$SESSION_DIR/.alerts-at"
printf 'refresh=success\nmade=%s\nok_at=%s\n' "$(( now - 9 * 86400 ))" "$now" > "$SESSION_DIR/.fc-status"
check "an old snapshot with a recent good refresh raises nothing" "0" "$(alerts_check | grep -c '^alert: the Firecracker snapshot')"
printf 'refresh=failed\nmade=%s\nok_at=%s\n' "$now" "$(( now - 4 * 86400 ))" > "$SESSION_DIR/.fc-status"
check "a failed refresh and no good one for 4 days raise both" "2" "$(alerts_check | grep -c '^alert: the Firecracker snapshot')"
printf 'refresh=success\nmade=%s\n' "$now" > "$SESSION_DIR/.fc-status"; alerts_check >/dev/null
# A made= value is data from the host: bash arithmetic would run a $(...) inside it.
rm -f "$SESSION_DIR/.alerts-at"
# A set variable name (PATH) gets past set -u, so the subscript's $(...) runs.
printf 'refresh=success\nmade=PATH[$(touch %s/pwned)]\n' "$tmp" > "$SESSION_DIR/.fc-status"
( alerts_check ) >/dev/null 2>&1; rc=$?
check "a made= value with a command in it runs nothing, and the alerts still finish" "no|0" "$([ -e "$tmp/pwned" ] && echo yes || echo no)|$rc"
# A manager unit in a restart loop raises one alert for that unit, and clears when it runs again.
rm -f "$SESSION_DIR/.fc-status"
_alert_units() { echo "fxa-grafana-iap.service activating auto-restart"; echo "fxa-agent-bot.service active running"; }
out="$(alerts_check)"
check "a unit in a restart loop raises, a running one does not" "1|0" "$(grep -c '^alert: the fxa-grafana-iap.service unit is failed or in a restart loop' <<< "$out")|$(grep -c 'fxa-agent-bot' <<< "$out")"
_alert_units() { echo "fxa-grafana-iap.service active running"; echo "fxa-agent-bot.service active running"; }
check "the unit running again clears it" "1" "$(alerts_check | grep -c '^cleared: unit')"
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
