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
echo "{\"key\":\"agent-al02\",\"booted_at\":\"$(( now - 600 ))\",\"boot_s\":\"95\"}" > "$SESSION_DIR/agent-al02.json"
echo "{\"key\":\"agent-al03\",\"booted_at\":\"$(( now - 600 ))\",\"boot_s\":\"12\"}" > "$SESSION_DIR/agent-al03.json"
echo "{\"at\":\"$(date -u +%FT%TZ)\",\"usd\":130}" > "$tmp/proxy/usage.jsonl"
out="$(alerts_check)"
check "idle, spend and slow boot raise; capacity does not" "1|1|1|0" \
  "$(grep -c '^alert: idle runner' <<< "$out")|$(grep -c '^alert: LLM spend' <<< "$out")|$(grep -c '^alert: the median boot' <<< "$out")|$(grep -c 'capacity' <<< "$out")"
check "a breach that lasts is not raised again" "" "$(alerts_check)"
rm "$tmp/proxy/usage.jsonl"
check "spend under the threshold again: resolved" "cleared: daily_spend" "$(alerts_check)"
echo "{\"at\":\"$(date -u +%FT%TZ)\",\"usd\":200}" > "$tmp/proxy/usage.jsonl"; sleep 1
check "a new breach raises again, so the operator gets a DM" "1" "$(alerts_check | grep -c '^alert: LLM spend')"
check "alerts_maybe runs at most once an hour" "" "$(touch "$SESSION_DIR/.alerts-at"; alerts_maybe)"
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
