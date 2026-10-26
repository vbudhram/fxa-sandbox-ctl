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
# FXA_ALERT_BOOT_S (60, median of 3+ boots), FXA_ALERT_CAPACITY (3 capacity errors),
# FXA_ALERT_SNAPSHOT_DAYS (3, the Firecracker snapshot's age). A failed or restarting fxa-* unit always alerts.

[ -n "${_FXA_ALERTS_LOADED:-}" ] && return 0
_FXA_ALERTS_LOADED=1

# _alert <name> <breached 0|1> <message>   Raise once while it lasts; resolve when it clears.
# An alert is found by its kind and the text before "; ", numbers masked: the detail after it (the slowest
# boot step) changes the signature, and a match on the signature raised a second alert and left the first open.
_alert() {
  local s open
  open="$(cmd_errors --json 2>/dev/null | jq -r --arg k "$1" --arg p "$3" 'def stem: split("; ")[0] | gsub("[0-9]+"; "N");
    .[] | select(.source == "alert" and .kind == $k and .status != "resolved" and (.message | stem) == ($p | stem)) | .sig' 2>/dev/null)"
  if [ "$2" = 1 ]; then
    [ -z "$open" ] || return 0
    errors_record alert "$1" "" "alerts" "$3" "" && echo "alert: $3"
  elif [ -n "$open" ]; then
    for s in $open; do cmd_errors resolve "$s" "cleared: under the threshold again" >/dev/null; done; echo "cleared: $1"
  fi
  return 0
}

alerts_check() {
  local since sessions idle spend boot cap usage="${FXA_LLM_PROXY_DIR:-$HOME/.claude/state/llm-proxy}/usage.jsonl"
  since=$(( $(date +%s) - 86400 ))
  sessions="$(_session_records | jq -sc '.' 2>/dev/null || echo '[]')"
  [ -n "$sessions" ] || sessions='[]'
  local def='def n: (. // 0 | tonumber? // 0);'
  idle="$(jq -r --argjson t "$since" "$def"' map(select((.stopped_at | n) >= $t)) | map(.idle_s | n) | add // 0' <<< "$sessions")"
  boot="$(jq -r --argjson t "$since" "$def"' [.[] | select((.booted_at | n) >= $t) | .boot_s | n | select(. > 0)] | sort
    | if length >= 3 then .[length / 2 | floor] else 0 end' <<< "$sessions")"
  spend=0
  if declare -F db_on >/dev/null && db_on; then spend="$(db_value "SELECT coalesce(sum(usd), 0) FROM llm_calls WHERE at >= strftime('%Y-%m-%dT%H:%M:%SZ', ${since}, 'unixepoch');")"
  elif [ -s "$usage" ]; then spend="$(jq -rs --argjson t "$since" 'map(select((.at // "" | fromdate? // 0) >= $t) | .usd // 0) | add // 0' "$usage" 2>/dev/null || echo 0)"; fi
  cap=0; [ -s "$ERRORS_FILE" ] && cap="$(jq -rs --argjson t "$since" 'map(select((.at | fromdate? // 0) >= $t and (.kind | IN("stockout", "all_zones_out", "session_cap")))) | length' "$ERRORS_FILE" 2>/dev/null || echo 0)"
  local ih="${FXA_ALERT_IDLE_HOURS:-6}" du="${FXA_ALERT_DAILY_USD:-150}" bs="${FXA_ALERT_BOOT_S:-60}" cn="${FXA_ALERT_CAPACITY:-3}"
  _alert idle_hours "$(awk -v i="$idle" -v h="$ih" 'BEGIN { print (i > h * 3600) }')" \
    "idle runner time in the last 24 h is $(awk -v i="$idle" 'BEGIN { printf "%.1f", i / 3600 }') h, over ${ih} h"
  _alert daily_spend "$(awk -v s="$spend" -v d="$du" 'BEGIN { print (s >= 0.8 * d) }')" \
    "LLM spend in the last 24 h is \$$(awk -v s="$spend" 'BEGIN { printf "%.0f", s }'), at least 80% of FXA_ALERT_DAILY_USD (\$${du})"
  # The step the slow boots spent most time in, so the alert names the cause (a cold Firecracker host shows as 'starting a runner').
  local slow; slow="$(jq -r --argjson t "$since" --argjson m "$bs" "$def"' [.[] | select((.booted_at | n) >= $t and (.boot_s | n) > $m)
    | (.boot_steps | if type == "string" then (fromjson? // []) else (. // []) end)[]? | {step, s: (.s | n)}]
    | group_by(.step) | map({step: .[0].step, s: (map(.s) | add / length)}) | max_by(.s) // empty
    | "; the slow boots spend most time in \(.step) (\(.s | floor) s each)"' <<< "$sessions" 2>/dev/null || true)"
  _alert slow_boot "$(awk -v b="$boot" -v m="$bs" 'BEGIN { print (b > m) }')" \
    "the median boot in the last 24 h is $(awk -v b="$boot" 'BEGIN { printf "%.0f", b }') s, over ${bs} s${slow}"
  _alert capacity "$([ "${cap:-0}" -ge "$cn" ] && echo 1 || echo 0)" \
    "${cap} capacity failures (zone stockouts or the session cap) in the last 24 h"
  # A manager unit in a restart loop or failed: nothing else reads systemd (grafana-iap looped for a week unseen).
  local u act sub
  while read -r u act sub; do
    [ -n "$u" ] || continue
    _alert unit "$([ "$act" = failed ] || [ "$sub" = auto-restart ] && echo 1 || echo 0)" \
      "the ${u} unit is failed or in a restart loop; journalctl -u ${u} shows why"
  done <<< "$(_alert_units)"
  # The snapshot refresh fails on the host, where nothing else sees it: sessions keep
  # booting from the old snapshot, only slower. fc_status reads it when the host is up.
  if declare -F fc_status >/dev/null && _fc_up; then fc_status >/dev/null 2>&1 || true; fi
  if declare -F fc_refresh_maybe >/dev/null; then fc_refresh_maybe >/dev/null 2>&1 || true; fi
  local fcs="${SESSION_DIR}/.fc-status" result made sd="${FXA_ALERT_SNAPSHOT_DAYS:-3}"
  if [ -f "$fcs" ]; then
    # Data from the host: only a plain number reaches arithmetic, which would run a $(...) in it.
    # The age counts from the last good refresh (ok_at), not from the snapshot: main can stay put for days.
    result="$(sed -n 's/^refresh=//p' "$fcs")"; made="$(sed -n 's/^ok_at=\([0-9][0-9]*\)$/\1/p' "$fcs" | head -1)"
    [ -n "$made" ] || made="$(sed -n 's/^made=\([0-9][0-9]*\)$/\1/p' "$fcs" | head -1)"
    _alert snapshot_refresh "$([ -n "$result" ] && [ "$result" != success ] && echo 1 || echo 0)" \
      "the Firecracker snapshot refresh failed; fxa-sandbox-ctl fc log shows why"
    made="${made:-$(date +%s)}"
    _alert snapshot_age "$([ $(( $(date +%s) - made )) -gt $(( sd * 86400 )) ] && echo 1 || echo 0)" \
      "the Firecracker snapshot has had no good refresh for $(( ($(date +%s) - made) / 86400 )) days, over ${sd}"
  fi
}

# _alert_units   "<unit> <active> <sub>" for each fxa-* service on this host; nothing where there is no systemd.
_alert_units() {
  command -v systemctl >/dev/null || return 0
  systemctl list-units 'fxa-*.service' --all --no-legend --plain 2>/dev/null | awk '{print $1, $3, $4}' || true
}

alerts_maybe() {
  local stamp="${SESSION_DIR}/.alerts-at"
  [ -f "$stamp" ] && [ $(( $(date +%s) - $(_mtime "$stamp") )) -lt 3600 ] && return 0
  touch "$stamp"
  alerts_check
}
