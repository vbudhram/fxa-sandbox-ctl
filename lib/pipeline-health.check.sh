#!/usr/bin/env bash
# Offline check of the pipeline health facts the Board reads: the 24 h launch budget and when it frees,
# the pass lock age, the pass timer, and the round cap.
#   bash lib/pipeline-health.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
command -v jq >/dev/null || { echo "skip: needs jq"; exit 0; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/config.sh"
eval "$(sed -n '/^_FXA_ROUND_CAP=/p;/^pipeline_launches_24h() {/,/^}/p;/^_pipeline_next_pass() {/,/^}/p;/^_pipeline_timer_unit() {/,/^}/p;/^_pipeline_pass_times() {/,/^}/p;/^pipeline_health_json() {/,/^}/p;/^pipeline_pause_marker() {/p' "$here/pipeline.sh")"
pipeline_require() { :; }; pipeline_free_gb() { echo 50; }
PIPE_STATE_DIR="$tmp/state"; PIPE_LOCK_DIR="$tmp/state/pass.lock"; mkdir -p "$PIPE_STATE_DIR"
now="$(date +%s)"; h() { pipeline_health_json | jq -r "$1"; }

printf '%s FXA-1 s\n' $((now - 90000)) $((now - 5000)) $((now - 4000)) $((now - 3000)) $((now - 2000)) > "$PIPE_STATE_DIR/launches.log"
check "the budget counts the last 24 h, oldest first" "$((now - 5000)) $((now - 2000))" "$(pipeline_launches_24h | sed -n '1p;$p' | tr '\n' ' ' | sed 's/ $//')"
check "4 launches against a cap of 3: full, and it frees when row n-max+1 leaves the window" "4|3|$((now - 4000 + 86400))" \
  "$(PIPE_MAX_LAUNCHES_PER_DAY=3 h '"\(.launches_24h)|\(.max_launches_per_day)|\(.launch_frees_at)"')"
check "under the cap: no free time" "4|20|null" "$(h '"\(.launches_24h)|\(.max_launches_per_day)|\(.launch_frees_at)"')"
rm "$PIPE_STATE_DIR/launches.log"
check "no ledger: 0 launches" "0|null" "$(h '"\(.launches_24h)|\(.launch_frees_at)"')"

check "no lock: no age, the stale limit" "null|1800" "$(h '"\(.lock_age_seconds)|\(.lock_stale_seconds)"')"
mkdir "$PIPE_LOCK_DIR"; touch -t "$(date -r $((now - 2400)) +%Y%m%d%H%M.%S 2>/dev/null || date -d @$((now - 2400)) +%Y%m%d%H%M.%S)" "$PIPE_LOCK_DIR"
a="$(h .lock_age_seconds)"; check "a lock made 40 min ago is about 2400 s old" "yes" "$([ "$a" -ge 2395 ] && [ "$a" -le 2460 ] && echo yes || echo "no ($a)")"

# The pass timer, from a systemctl on PATH.
# show answers on the property name ($3), in the line shapes the manager VM prints (systemd 255).
mkdir "$tmp/bin"; printf '#!/bin/sh\ncase "$1" in is-active) [ -e "%s/on" ] && [ "$3" = fxa-pass.timer ] ;; show) case "$3" in TimersCalendar) cat "%s/cal" ;; *) cat "%s/next" ;; esac ;; esac\n' "$tmp" "$tmp" "$tmp" > "$tmp/bin/systemctl"; chmod +x "$tmp/bin/systemctl"
printf '%s\n' '{ OnCalendar=Sat,Sun *-*-* 07..19:04:00 America/New_York ; next_elapse=Sat 2026-10-24 11:04:00 UTC }' \
  '{ OnCalendar=Mon..Fri *-*-* 07..19:04/5:00 America/New_York ; next_elapse=Mon 2026-10-19 11:04:00 UTC }' > "$tmp/cal"
echo "@$((now + 600))" > "$tmp/next"; touch "$tmp/on"
check "an active timer gives its next time and on" "$((now + 600))|on" "$(PATH="$tmp/bin:$PATH" h '"\(.next_pass_epoch)|\(.pass_timer)"')"
if date -d "@0" +%s >/dev/null 2>&1; then
  date -u -d "@$((now + 900))" '+%a %Y-%m-%d %H:%M:%S UTC' > "$tmp/next"
  check "systemd's own date text reads as its epoch (GNU date)" "$((now + 900))" "$(PATH="$tmp/bin:$PATH" h .next_pass_epoch)"
fi
check "FxA's pass under its pipeline name reads fxa-pass.timer" "on" "$(FXA_PIPELINE=fxa-ai-fixme PATH="$tmp/bin:$PATH" h .pass_timer)"
rm "$tmp/on"; check "a timer that is not active: off, no time" "null|off" "$(PATH="$tmp/bin:$PATH" h '"\(.next_pass_epoch)|\(.pass_timer)"')"
# pass_times: every elapse line of each spec, sorted, kept in the next 24 h. The calendar stub prints
# systemd-analyze's own layout and logs each spec it got, one argument a line.
cat > "$tmp/bin/systemd-analyze" <<SH
#!/bin/sh
printf '%s\\n' "\$4" >> "$tmp/specs"
case "\$4" in Sat*) cat "$tmp/cal-a" ;; *) cat "$tmp/cal-b" ;; esac
SH
chmod +x "$tmp/bin/systemd-analyze"; touch "$tmp/on"
if date -d "@0" +%s >/dev/null 2>&1; then
  t() { date -u -d "@$1" '+%a %Y-%m-%d %H:%M:%S UTC'; }
  printf '%s\n' 'Normalized form: Sat,Sun *-*-* 07..19:04:00 America/New_York' "    Next elapse: $(t $((now + 600)))" '       From now: 10min left' \
    "   Iteration #2: $(t $((now + 90000)))" > "$tmp/cal-a"
  printf '%s\n' "    Next elapse: $(t $((now + 300)))" "   Iteration #2: $(t $((now + 450)))" '   Iteration #3: not a date' "   Iteration #4: $(t $((now + 600)))" > "$tmp/cal-b"
  echo "@$((now + 300))" > "$tmp/next"; : > "$tmp/specs"
  want="[$((now + 300)),$((now + 450)),$((now + 600))]"
  check "pass_times: both specs, one sorted 24 h list; a late time and a bad line drop out" "$want" "$(PATH="$tmp/bin:$PATH" h '.pass_times | tojson')"
  check "pass_times: its first time is next_pass_epoch" "true" "$(PATH="$tmp/bin:$PATH" h '.pass_times[0] == .next_pass_epoch')"
  check "pass_times: each spec reached the tool as one argument" "Sat,Sun *-*-* 07..19:04:00 America/New_York|Mon..Fri *-*-* 07..19:04/5:00 America/New_York" \
    "$(sort -u "$tmp/specs" | sort -r | paste -sd '|' -)"
  mkdir -p "$tmp/cwd" && touch "$tmp/cwd/a-b-c"
  check "pass_times: a file that matches the spec as a glob changes nothing" "$want" "$(cd "$tmp/cwd" && PATH="$tmp/bin:$PATH" h '.pass_times | tojson')"
fi
check "pass_times: no calendar tool gives null" "null" "$(FXA_SYSTEMD_ANALYZE=/nonexistent PATH="$tmp/bin:$PATH" h '.pass_times | tojson')"
rm -f "$tmp/on"; check "pass_times: a timer that is off gives []" "[]" "$(PATH="$tmp/bin:$PATH" h '.pass_times | tojson')"
check "pass_times: no systemctl gives null" "null" "$(PATH="/usr/bin:/bin" command -v systemctl >/dev/null && echo null || PATH="/usr/bin:/bin" h '.pass_times | tojson')"
check "no systemctl: both unknown" "null|null" "$(PATH="/usr/bin:/bin" command -v systemctl >/dev/null && echo "null|null" || PATH="/usr/bin:/bin" h '"\(.next_pass_epoch)|\(.pass_timer)"')"
check "one round cap" "2" "$_FXA_ROUND_CAP"
eval "$(sed -n '/^_snapshot_last_pass() {/,/^}/p' "$here/snapshot.sh")"
check "no passes file: last_pass is null" "null" "$(_snapshot_last_pass)"
printf '%s\n' '{"at":1,"woke":{}}' '{"at":2,"woke":{"queue":1}}' > "$PIPE_STATE_DIR/passes.jsonl"
check "last_pass is the last row" "2" "$(_snapshot_last_pass | jq .at)"
echo 'not json' >> "$PIPE_STATE_DIR/passes.jsonl"; check "a row that does not parse gives null" "null" "$(_snapshot_last_pass)"
check "the snapshot writes limits from the round cap" "1" "$(grep -c 'limits: { attempts: $roundcap, feedback_rounds: $roundcap, merged_prs: $mcap }' "$here/snapshot.sh")"
exit "$fail"
