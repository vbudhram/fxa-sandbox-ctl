#!/bin/bash
# alerts.sh: threshold checks over the last 24 h. A breach goes to the error log,
# which DMs the operator for a new or reopened signature; a cleared one is
# resolved, so the next breach DMs again.
#
# Public API:
#   alerts_check          run every check now; prints one line per alert raised or cleared
#   alerts_maybe          alerts_check at most once an hour (the idle sweep calls it)
#
# Thresholds (env): FXA_ALERT_IDLE_HOURS (6), FXA_ALERT_DAILY_USD (150, alert at 80%),
# FXA_ALERT_BOOT_S (60, median of 3+ boots), FXA_ALERT_CAPACITY (3 capacity errors).

[ -n "${_FXA_ALERTS_LOADED:-}" ] && return 0
_FXA_ALERTS_LOADED=1

# _alert <name> <breached 0|1> <message>   Raise once while it lasts; resolve when it clears.
# The message's numbers are masked in the signature, so one alert keeps one signature.
_alert() {
  local sig status
  sig="$(errors_sig "alerts" "$3")"
  status="$(cmd_errors --json 2>/dev/null | jq -r --arg s "$sig" '.[] | select(.sig == $s) | .status' 2>/dev/null)"
  if [ "$2" = 1 ]; then
    case "$status" in open|reopened) return 0 ;; esac
    errors_record alert "$1" "" "alerts" "$3" "" && echo "alert: $3"
  elif [ "$status" = open ] || [ "$status" = reopened ]; then
    cmd_errors resolve "$sig" "cleared: under the threshold again" >/dev/null && echo "cleared: $1"
  fi
  return 0
}

alerts_check() {
  local since sessions idle spend boot cap usage="${FXA_LLM_PROXY_DIR:-$HOME/.claude/state/llm-proxy}/usage.jsonl"
  since=$(( $(date +%s) - 86400 ))
  sessions="$(for f in "$SESSION_DIR"/agent-*.json; do [ -f "$f" ] && cat "$f"; done | jq -sc '.' 2>/dev/null || echo '[]')"
  [ -n "$sessions" ] || sessions='[]'
  local def='def n: (. // 0 | tonumber? // 0);'
  idle="$(jq -r --argjson t "$since" "$def"' map(select((.stopped_at | n) >= $t)) | map(.idle_s | n) | add // 0' <<< "$sessions")"
  boot="$(jq -r --argjson t "$since" "$def"' [.[] | select((.booted_at | n) >= $t) | .boot_s | n | select(. > 0)] | sort
    | if length >= 3 then .[length / 2 | floor] else 0 end' <<< "$sessions")"
  spend=0; [ -s "$usage" ] && spend="$(jq -rs --argjson t "$since" 'map(select((.at // "" | fromdate? // 0) >= $t) | .usd // 0) | add // 0' "$usage" 2>/dev/null || echo 0)"
  cap=0; [ -s "$ERRORS_FILE" ] && cap="$(jq -rs --argjson t "$since" 'map(select((.at | fromdate? // 0) >= $t and (.kind | IN("stockout", "all_zones_out", "session_cap")))) | length' "$ERRORS_FILE" 2>/dev/null || echo 0)"
  local ih="${FXA_ALERT_IDLE_HOURS:-6}" du="${FXA_ALERT_DAILY_USD:-150}" bs="${FXA_ALERT_BOOT_S:-60}" cn="${FXA_ALERT_CAPACITY:-3}"
  _alert idle_hours "$(awk -v i="$idle" -v h="$ih" 'BEGIN { print (i > h * 3600) }')" \
    "idle runner time in the last 24 h is $(awk -v i="$idle" 'BEGIN { printf "%.1f", i / 3600 }') h, over ${ih} h"
  _alert daily_spend "$(awk -v s="$spend" -v d="$du" 'BEGIN { print (s >= 0.8 * d) }')" \
    "LLM spend in the last 24 h is \$$(awk -v s="$spend" 'BEGIN { printf "%.0f", s }'), at least 80% of FXA_ALERT_DAILY_USD (\$${du})"
  _alert slow_boot "$(awk -v b="$boot" -v m="$bs" 'BEGIN { print (b > m) }')" \
    "the median boot in the last 24 h is $(awk -v b="$boot" 'BEGIN { printf "%.0f", b }') s, over ${bs} s"
  _alert capacity "$([ "${cap:-0}" -ge "$cn" ] && echo 1 || echo 0)" \
    "${cap} capacity failures (zone stockouts or the session cap) in the last 24 h"
}

alerts_maybe() {
  local stamp="${SESSION_DIR}/.alerts-at"
  [ -f "$stamp" ] && [ $(( $(date +%s) - $(_mtime "$stamp") )) -lt 3600 ] && return 0
  touch "$stamp"
  alerts_check
}
