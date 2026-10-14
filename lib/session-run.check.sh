#!/usr/bin/env bash
# Offline check for boot timings, the live watch, Open PR repair, usage, backups, saved work, session try and media.
#   bash lib/session-run.check.sh
source "$(dirname "$0")/session-check-head.sh"

# Boot timings: each step lasts until the next starts; a repeated label is one step.
printf '%s\n' '#t0	1790000000.000' '0.4	Restoring x from the Firecracker snapshot' '2.6	slot 1 ip=10.42.16.11 restore_ms=185 ssh_ms=2228' \
  '2.7	Waiting for ssh on x' '3.8	Waiting for fxa-gce-checkout...' '4.1	Waiting for infrastructure services' '5.0	Pinning the runner' \
  '8.2	Applying security hardening...' '11.9	Starting claude in VM...' '12.5	Shipping 4 run file(s)' "14.9	=== Agent 'x' is running ===" > "$tmp/agent-bt1.boot.tsv"
bt="$(_session_boot_times agent-bt1)"
check "boot steps and times" "restoring=2.3 waiting=1.1 waiting=1.2 checking=3.2 locking=3.7 starting=3" \
  "$(jq -r '[.steps[] | "\(.step | split(" ")[0])=\(.s)"] | join(" ")' <<< "$bt")"
check "a finished boot has its total and the restore detail" "true 14.9 185 20" "$(jq -r '"\(.done) \(.total) \(.restore.restore_ms) \(.expect)"' <<< "$bt")"
check "no timings file is null" "null" "$(_session_boot_times agent-none)"
check "a new session's step names its commit" "on main at 3dfbfbf61a, fetched 20:28 UTC" "$(_session_boot_label 'On main at 3dfbfbf61a, fetched 20:28 UTC')"
check "a resumed session's step names the earlier base" "on the earlier base at 3dfbfbf61a" "$(_session_boot_label 'Resuming agent-a at 3dfbfbf61a, conversation 1234abcd...')"

check "the cap is FXA_SESSION_MAX without slots" "2" "$(FXA_FC_HOST= FXA_SESSION_MAX=2 _session_cap)"
check "with slots it is at least the slot count" "4 6" "$(FXA_FC_HOST=h FXA_SESSION_MAX=2 _session_cap) $(FXA_FC_HOST=h FXA_SESSION_MAX=6 _session_cap)"
# The GCS pause marker is read once per 30 s; this host's own pause clears the cache.
gcloud() { echo x >> "$tmp/gcs-reads"; case "$2" in cat) [ -f "$tmp/gcs-marker" ] && cat "$tmp/gcs-marker" ;; cp) cat > "$tmp/gcs-marker" ;; rm) rm -f "$tmp/gcs-marker" ;; esac; }
_SESSIONS_PAUSE_URI=gs://b/sessions/PAUSED; rm -f "$tmp/gcs-reads"
sessions_paused >/dev/null; sessions_paused >/dev/null
check "two reads in 30 s make one GCS call" "1" "$(wc -l < "$tmp/gcs-reads" | tr -d ' ')"
sessions_pause "spend" >/dev/null
check "a pause here is seen at once" "spend" "$(sessions_paused)"
sessions_resume >/dev/null
check "and a resume" "no" "$(sessions_paused >/dev/null && echo yes || echo no)"
unset -f gcloud; _SESSIONS_PAUSE_URI=""
# The watch forwards the reply's text as it is written, but not a subagent's.
w="$( _session_sh() { printf '%s\n' '{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"content_block_start","content_block":{"type":"text"}}}' \
  '{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}}' \
  '{"type":"stream_event","parent_tool_use_id":"t1","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"sub"}}}' '{"type":"result"}'; }
  _session_watch agent-t2 | jq -r '.type + (if .text then ":" + .text else "" end)' | paste -sd' ' - )"
check "watch streams the reply text" "text_start text:Hi result" "$w"
# The watch: existing events unchanged, plus the live-status events.
long="$(head -c 5000 /dev/zero | tr '\0' x)"
w="$(printf '%s\n' \
  '{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"content_block_start","content_block":{"type":"text"}}}' \
  '{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"hi"}}}' \
  '{"type":"stream_event","parent_tool_use_id":"s1","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"sub"}}}' \
  '{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"tool_use","id":"a1","name":"TodoWrite","input":{"todos":[{"content":"Find it","status":"completed","activeForm":"Finding it"},{"content":"Fix it","status":"in_progress","activeForm":"Fixing it"}]}}]}}' \
  '{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"tool_use","id":"s1","name":"Agent","input":{"description":"find the limiter","subagent_type":"fxa-explore","prompt":"p"}}]}}' \
  '{"type":"assistant","parent_tool_use_id":"s1","message":{"content":[{"type":"tool_use","id":"b1","name":"TodoWrite","input":{"todos":[{"content":"sub todo","status":"pending"}]}}]}}' \
  '{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"tool_use","id":"e1","name":"Edit","input":{"file_path":"/workspace/libs/a.ts","old_string":"x\ny","new_string":"x\ny\nz"}},{"type":"tool_use","id":"e2","name":"Write","input":{"file_path":"/home/agent/fxa/b.ts","content":"1\n2"}}]}}' \
  '{"type":"user","parent_tool_use_id":null,"message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"PASS\nTests:       1 failed, 44 passed, 45 total\n"}]}}' \
  '{"type":"user","parent_tool_use_id":null,"message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":[{"type":"text","text":"  12 passing (3s)\n  2 failing\n"}]}]}}' \
  '{"type":"user","parent_tool_use_id":null,"message":{"content":[{"type":"tool_result","tool_use_id":"t3","is_error":true,"content":"✖ 3 problems (2 errors, 1 warning)\nFound 4 errors in 2 files."}]}}' \
  "{\"type\":\"user\",\"parent_tool_use_id\":null,\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"t4\",\"content\":\"Tests: 9 passed $long\"}]}}" \
  '{"type":"user","parent_tool_use_id":"s1","message":{"content":[{"type":"tool_result","tool_use_id":"b2","content":"Tests: 3 passed"}]}}' \
  '{"type":"item.completed","item":{"type":"file_change","changes":[{"path":"a/b.ts"}]}}' \
  '{"type":"result","result":"ok"}' | jq -R -c "$_SESSION_WATCH_JQ" | jq -s -c '.')"
check "watch: text events unchanged" 'text_start|hi' "$(jq -r '[.[] | select(.type == "text_start" or .type == "text") | .text // .type] | join("|")' <<< "$w")"
check "watch: a subagent's text is not streamed" "0" "$(jq '[.[] | select(.text == "sub")] | length' <<< "$w")"
check "watch: steps, a subagent's marked" 'Updating the plan|Delegating to fxa-explore: find the limiter|↳ Updating the plan|Editing a.ts|Editing b.ts|Editing b.ts' "$(jq -r '[.[] | select(.type == "step") | .text] | join("|")' <<< "$w")"
check "watch: the main agent's todos" 'Find it:completed:Finding it|Fix it:in_progress:Fixing it' "$(jq -r '[.[] | select(.type == "todos") | .items[] | "\(.content):\(.status):\(.active)"] | join("|")' <<< "$w")"
check "watch: a subagent's todos are not the plan" "1" "$(jq '[.[] | select(.type == "todos")] | length' <<< "$w")"
check "watch: a subagent starts" 's1 fxa-explore find the limiter' "$(jq -r '.[] | select(.type == "subagent_start") | "\(.id) \(.agent) \(.description)"' <<< "$w")"
check "watch: edits with line counts" 'libs/a.ts +3 -2|b.ts +2 -0' "$(jq -r '[.[] | select(.type == "edit") | "\(.file) +\(.added) -\(.removed)"] | join("|")' <<< "$w")"
check "watch: jest and mocha counts" '44/1|12/2' "$(jq -r '[.[] | select(.type == "tests") | "\(.passed)/\(.failed)"] | join("|")' <<< "$w")"
check "watch: lint and type-check counts" 'lint 2/1 types 4' "$(jq -r '"lint \(.[] | select(.type == "lint") | "\(.errors)/\(.warnings)") types \(.[] | select(.type == "types") | .errors)"' <<< "$w")"
check "watch: only the last 4 KB of output is read" "0" "$(jq '[.[] | select(.type == "tests" and .passed == 9)] | length' <<< "$w")"
check "watch: a subagent's tool output is not counted" "0" "$(jq '[.[] | select(.type == "tests" and .passed == 3)] | length' <<< "$w")"
check "watch: tool results are marked done" 't1:true t2:true t3:false t4:true' "$(jq -r '[.[] | select(.type == "tool_done") | "\(.id):\(.ok)"] | join(" ")' <<< "$w")"
check "watch: a script that writes a file is an edit, one that reads is not" 'Editing with a script: python3 - <<EOF|Running python3 -c print(1)' \
  "$(printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"p1","name":"Bash","input":{"command":"python3 - <<EOF\np=\"a.tsx\"; s=open(p).read()\nopen(p, \"w\").write(s.replace(\"a\", \"b\"))\nEOF"}},{"type":"tool_use","id":"p2","name":"Bash","input":{"command":"python3 -c print(1)"}}]}}' \
    | jq -R -c "$_SESSION_WATCH_JQ" | jq -r 'select(.type == "step") | .text' | sed 's/^\(Editing with a script: python3 - <<EOF\).*/\1/' | paste -sd'|' -)"
check "watch: a codex message streams as a block of text, as Claude's reply does" '{"type":"text_start"}|{"type":"text","text":"I will trace the cache first."}' \
  "$(echo '{"type":"item.completed","item":{"type":"agent_message","text":"I will trace the cache first."}}' | jq -R -c "$_SESSION_WATCH_JQ" | paste -sd'|' -)"
check "watch: a codex item is a step only" '{"type":"step","text":"Editing b.ts"}' "$(echo '{"type":"item.completed","item":{"type":"file_change","changes":[{"path":"a/b.ts"}]}}' | jq -R -c "$_SESSION_WATCH_JQ")"
check "watch: the result ends it" "result" "$(jq -r 'last | .type' <<< "$w")"
todo="$(jq -n -c '{type: "assistant", parent_tool_use_id: null, message: {content: [{type: "tool_use", id: "w1", name: "Write",
  input: {file_path: "/workspace/.fxa-todo.md", content: "# Plan\n- [x] Find it\n- [>] Fix it\n- [ ] Test it\nnot a todo"}}]}}' | jq -R -c "$_SESSION_WATCH_JQ" | jq -s -c '.')"
check "watch: the todo file is the plan" 'Find it:completed|Fix it:in_progress|Test it:pending' "$(jq -r '[.[] | select(.type == "todos") | .items[] | "\(.content):\(.status)"] | join("|")' <<< "$todo")"
check "watch: the todo file is not an edit, and its step says so" 'Updating the plan|0' "$(jq -r '"\(.[] | select(.type == "step") | .text)|\([.[] | select(.type == "edit")] | length)"' <<< "$todo")"

# Open PR: the runner's handoff check gets one repair turn; a second failure stops the ship.
HC="$tmp/hc-exits" # not $tmp: _cmd_session_finish has a local tmp
finish_case() { # finish_case <check exits...>   prints the turns, then pushed or the error
  ( echo '{"key":"agent-hc1","state":"wrapping","runtime":"claude"}' > "$SESSION_DIR/agent-hc1.json"
    : > "$SESSION_DIR/agent-hc1.finish.log"; echo "$*" > "$HC"
    runtime_load() { :; }; sleep() { :; }; _session_turn_running() { return 1; }; errors_record() { :; }
    _session_turn() { echo "turn:$(head -1 <<<"$2" | cut -c1-12)"; }
    vm_exec() { return 0; }
    _session_sh() { local e; read -r e rest < "$HC"; echo "${rest:-}" > "$HC"
      [ "$e" = 0 ] && echo "handoff check: ok" || echo "handoff check: pr_title is not a scoped conventional subject"; return "$e"; }
    session_checkout() { mkdir -p "$2"; }; session_checkout_remove() { :; }
    finish_push_and_pr() { echo pushed >&2; echo https://github.com/o/r/pull/1; }
    _session_finish_notes() { :; }; _session_record_summary() { :; }; _thread_ok() { return 1; }
    _cmd_session_finish agent-hc1 2>&1 | grep -E '^(turn:|pushed$)' | paste -sd'|' -
    session_get agent-hc1 last_error )
}
check "a clean check ships with no repair turn" "turn:The engineer|pushed" "$(finish_case 0)"
check "a failed check gets one repair turn, then ships" "turn:The engineer|turn:The host's c|pushed" "$(finish_case 1 0)"
check "a second failure stops the ship and says why" "turn:The engineer|turn:The host's c
Open PR failed: handoff check: pr_title is not a scoped conventional subject" "$(finish_case 1 1)"
check "style alone gets one repair turn and ships even if it stays" "turn:The engineer|turn:The host's c|pushed" "$(finish_case 3 3)"
check "an unreachable runner skips the check" "turn:The engineer|pushed" "$(finish_case 255)"
check "a check missing on the runner stops the ship (a Codex runner once had none)" "turn:The engineer
Open PR failed: the host's handoff check is missing on the runner, so nothing was pushed" "$(finish_case 127)"

# Usage records: one line per turn, and at stop the runner, busy and idle seconds with the reason.
echo '{"key":"agent-us01","state":"active","turns":"2"}' > "$SESSION_DIR/agent-us01.json"
now=$(date +%s)
session_set agent-us01 booted_at "$(( now - 600 ))" turn_started "$(( now - 100 ))" turn_open 1
_session_turn_log agent-us01 '{"cost":1.25,"tokens":900}'
_session_turn_log agent-us01 '{"cost":9,"tokens":9}'
check "a turn is logged once, with its cost so far" "1|2|1.25" "$(wc -l < "$SESSION_DIR/agent-us01.turns.jsonl" | tr -d ' ')|$(jq -r .turn "$SESSION_DIR/agent-us01.turns.jsonl")|$(jq -r .cost_so_far "$SESSION_DIR/agent-us01.turns.jsonl")"
check "the turn's seconds" "1" "$(jq -r '.secs >= 99 and .secs <= 102 | if . then 1 else 0 end' "$SESSION_DIR/agent-us01.turns.jsonl")"
session_set agent-us01 turn_open 0
_session_usage_close agent-us01 idle
# The turn ends when the clock says, so busy is 100 s give or take a second.
check "stop: reason and the runner's busy and idle seconds" "idle|1|1" "$(session_get agent-us01 stop_reason)|$(s=$(session_get agent-us01 runner_s); [ "$s" -ge 600 ] && [ "$s" -le 602 ] && echo 1)|$(b=$(session_get agent-us01 busy_s); [ "$b" -ge 99 ] && [ "$b" -le 102 ] && echo 1)"
check "idle is runner minus busy" "$(( $(session_get agent-us01 runner_s) - $(session_get agent-us01 busy_s) ))" "$(session_get agent-us01 idle_s)"
_session_usage_close agent-us01 later
check "a second close keeps the first reason" "idle" "$(session_get agent-us01 stop_reason)"
echo '{"key":"agent-us02","state":"starting"}' > "$SESSION_DIR/agent-us02.json"
_session_usage_close agent-us02 stopped
check "a session that never booted gets only the reason" "stopped|" "$(session_get agent-us02 stop_reason)|$(session_get agent-us02 runner_s)"
_session_res_peaks agent-us01 "1.5 4000 40"; _session_res_peaks agent-us01 "0.7 9000 35"; _session_res_peaks agent-us01 ""
check "resource peaks keep the highest of each" '{"load1":1.5,"mem_mb":9000,"disk_pct":40}' "$(session_get agent-us01 res_peak)"
# The proxy's call log keeps 90 days.
mkdir -p "$tmp/proxy"; printf '%s\n' '{"at":"2020-01-01T00:00:00Z","usd":1}' "{\"at\":\"$(date -u +%FT%TZ)\",\"usd\":2}" > "$tmp/proxy/usage.jsonl"
FXA_LLM_PROXY_DIR="$tmp/proxy" FXA_MCP_GATEWAY_DIR="$tmp/none" session_prune >/dev/null
check "prune drops proxy calls older than 90 days" "2" "$(jq -r .usd "$tmp/proxy/usage.jsonl")"

# The backup: at most daily, --now forces it, a failed upload tries again next sweep.
( calls="$tmp/gcloud.calls"; gcloud() { echo "$*" >> "$calls"; [ ! -f "$tmp/gcloud.fail" ]; }
  _mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
  export FXA_SESSION_BACKUP_URI="gs://b/sessions"; rm -f "$SESSION_DIR/.backed-up"
  session_backup; session_backup
  check "backup: once a day" "1" "$(wc -l < "$calls" | tr -d ' ')"
  check "backup: to the host's folder, without the launch staging" "yes|yes" "$(grep -q "gs://b/sessions/$(hostname -s)" "$calls" && echo yes)|$(grep -q 'run/' "$calls" && echo yes)"
  session_backup --now
  check "backup: --now goes anyway" "2" "$(wc -l < "$calls" | tr -d ' ')"
  touch "$tmp/gcloud.fail"
  check "backup: a failed upload fails" "1" "$(session_backup --now; echo $?)"
  rm -f "$tmp/gcloud.fail"; session_backup
  check "backup: and tries again on the next sweep" "4" "$(wc -l < "$calls" | tr -d ' ')"
  FXA_SESSION_BACKUP_URI=""; session_backup --now
  check "backup: no bucket, nothing to do" "4" "$(wc -l < "$calls" | tr -d ' ')"
  mkdir -p "$tmp/bk"; echo "{\"key\":\"agent-bk1\",\"state\":\"stopped\",\"last_activity\":1}" > "$tmp/bk/agent-bk1.json"
  FXA_SESSION_BACKUP_URI="gs://b/sessions" SESSION_DIR="$tmp/bk" FXA_MCP_GATEWAY_DIR="$tmp/none" FXA_LLM_PROXY_DIR="$tmp/none" session_prune >/dev/null
  check "prune: deletes the pruned session's backup copy" "yes" "$(grep -q "rm -q -r gs://b/sessions/$(hostname -s)/agent-bk1\.\*" "$calls" && echo yes)"
  exit "$fail" ) || fail=1

# Saved work: up to the bucket after a save, back when this disk has none, gone at prune.
( calls="$tmp/gs.calls"; bucket="$tmp/bucket"; mkdir -p "$bucket"; rm -f "$calls"
  export FXA_SESSION_STORE_URI="gs://b/saved"
  gcloud() { echo "$*" >> "$calls"; [ ! -f "$tmp/gs.fail" ] || return 1
    case "$2" in cp) shift 3; local dst="${@: -1}"; set -- "${@:1:$#-1}"
         if [ "${dst#gs://}" != "$dst" ]; then cp "$@" "$bucket/"; else cp "$bucket/$(basename "$1")" "$dst" 2>/dev/null || return 1; fi ;;
       rm) shift 3; rm -f "$bucket/$(basename "$1")" ;; esac; }
  errors_record() { echo "$2" >> "$tmp/gs.errors"; }
  printf 'p' > "$SESSION_DIR/agent-up01.patch"; printf 't' > "$SESSION_DIR/agent-up01.claude.tgz"
  _session_upload agent-up01
  check "saved: both files go up in one call" "1|agent-up01.claude.tgz agent-up01.patch" "$(wc -l < "$calls" | tr -d ' ')|$(ls "$bucket" | tr '\n' ' ' | sed 's/ $//')"
  _session_fetch agent-up01
  check "saved: no fetch while this disk has them" "1" "$(wc -l < "$calls" | tr -d ' ')"
  rm -f "$SESSION_DIR/agent-up01".*
  gcloud() { echo "$*" >> "$calls"; cp "$bucket"/agent-up01.* "${@: -1}"; }
  _session_fetch agent-up01
  check "saved: a lost disk gets them back" "p|t" "$(cat "$SESSION_DIR/agent-up01.patch")|$(cat "$SESSION_DIR/agent-up01.claude.tgz")"
  gcloud() { echo "$*" >> "$calls"; return 1; }
  check "saved: a failed upload is recorded and fails" "1|upload_failed" "$(_session_upload agent-up01; echo $?)|$(cat "$tmp/gs.errors")"
  : > "$calls"; _session_upload agent-none
  check "saved: nothing saved, no call" "0" "$(wc -l < "$calls" | tr -d ' ')"
  FXA_SESSION_STORE_URI=""; _session_upload agent-up01
  check "saved: no bucket, no call" "0" "$(wc -l < "$calls" | tr -d ' ')"
  exit "$fail" ) || fail=1

# A pause nobody came back to in a day is closed: stopped, reason inactive. A fresh one stays.
now_s=$(date +%s)
printf '{"key":"agent-day1","state":"paused","last_activity":%s}\n' "$(( now_s - 90000 ))" > "$SESSION_DIR/agent-day1.json"
printf '{"key":"agent-day2","state":"paused","last_activity":%s}\n' "$(( now_s - 60 ))" > "$SESSION_DIR/agent-day2.json"
out="$(session_idle_sweep 2>/dev/null)"
check "a day-old pause is stopped as inactive" "1|stopped|inactive" "$(grep -cx 'stopped agent-day1' <<< "$out")|$(session_get agent-day1 state)|$(session_get agent-day1 stop_reason)"
check "a fresh pause stays paused" "0|paused" "$(grep -c 'agent-day2' <<< "$out")|$(session_get agent-day2 state)"

# The request and the guide travel in the prompt; a resumed turn gets only the request.
( mkdir -p "$tmp/pt"; printf 'Fix the <<<REQUEST-ab>>> login\n' > "$tmp/pt/.fxa-jira-context.md"; vm_guide_build() { echo "GUIDE $1"; }
  first="$(_session_prompt_tail "$tmp/pt" 0)"; again="$(_session_prompt_tail "$tmp/pt" 1)"
  check "prompt: a first turn carries the request and the session guide" "1|1" "$(grep -c 'Fix the <<<REQUEST-ab>>> login' <<< "$first")|$(grep -c '^GUIDE session$' <<< "$first")"
  check "prompt: a resumed turn carries only the request" "1|0" "$(grep -c 'Fix the' <<< "$again")|$(grep -c 'GUIDE' <<< "$again")"
  exit "$fail" ) || fail=1

# session try: start, wait for each turn through events, send --then, report, stop.
( ctl="$tmp/fakectl"; log="$tmp/try.log"; : > "$log"; echo 0 > "$tmp/polls"
  cat > "$ctl" <<STUB
#!/bin/bash
shift 2   # --backend gce
echo "\$*" >> "$log"
case "\$1" in
  task) [ -f "$tmp/try-fail" ] && exit 1; exit 0 ;;
  steer|stop) exit 0 ;;
  events) n=\$(( \$(cat "$tmp/polls") + 1 )); echo \$n > "$tmp/polls"
    if [ -f "$tmp/try-ends" ]; then echo '{"state":"failed","cursor":1,"events":[]}'
    elif [ \$(( n % 2 )) = 0 ]; then echo "{\\"state\\":\\"active\\",\\"cursor\\":\$n,\\"events\\":[{\\"type\\":\\"turn_end\\"}]}"
    else echo "{\\"state\\":\\"active\\",\\"cursor\\":\$n,\\"events\\":[{\\"type\\":\\"step\\"}]}"; fi ;;
  session) echo '[{"role":"user","text":"q"},{"role":"agent","text":"the reply"}]' ;;
esac
STUB
  chmod +x "$ctl"; export _SESSION_TRY_CTL="$ctl" FXA_TRY_POLL_SECONDS=0
  db_on() { false; }; _session_sh() { echo "main: {}; tools {}"; }; worktree_branch_for() { echo "$1"; }
  out="$(session_try --prompt "change it" --then "now review" 2>&1)"
  check "try: two turns, each reply, then a stop" "2|2|1|1" "$(grep -c '^the reply$' <<< "$out")|$(grep -c '^== turn [12],' <<< "$out")|$(grep -c '^steer agent-try' "$log")|$(grep -c '^stop agent-try' "$log")"
  check "try: it waits through steps, polling from the last cursor" "events agent-try" "$(grep -m1 -o '^events agent-try' "$log")"
  check "try: a dry-run owner" "1" "$(grep -c -- '--owner U-DRYRUN' "$log")"
  : > "$log"; out="$(session_try --prompt "x" --keep 2>&1)"
  check "try --keep: no stop, and says how" "0|1" "$(grep -c '^stop' "$log")|$(grep -c 'kept: fxa-sandbox-ctl stop' <<< "$out")"
  : > "$log"; touch "$tmp/try-ends"; out="$(session_try --prompt "x" 2>&1)"; rc=$?; rm -f "$tmp/try-ends"
  check "try: a session that ends early fails, and is still stopped" "1|1|1" "$rc|$(grep -c 'the session ended: failed' <<< "$out")|$(grep -c '^stop' "$log")"
  touch "$tmp/try-fail"; out="$(session_try --prompt "x" 2>&1)"; rc=$?; rm -f "$tmp/try-fail"
  check "try: a session that does not start says where to look" "1|1" "$rc|$(grep -c 'did not start' <<< "$out")"
  check "try: a prompt is required" "1" "$(session_try >/dev/null 2>&1; echo $?)"
  exit "$fail" ) || fail=1

runtime_skill_ref() { printf '/%s' "$1"; }
check "the first prompt carries the voice" "1" "$(SANDBOX_ROOT="$(cd "$(dirname "$0")/.." && pwd)" _session_first_prompt | grep -c 'helpful fox')"
check "the first prompt names !usage and runs nothing" "1|" "$(SANDBOX_ROOT="$(cd "$(dirname "$0")/.." && pwd)" _session_first_prompt 2>"$tmp/fp.err" | grep -c 'point to `!usage`')|$(cat "$tmp/fp.err")"

# The live file count comes from git on the runner, so edits made with a script count too.
g="$tmp/diffrepo"; git init -q "$g"; printf 'a\nb\n' > "$g/old.ts"; git -C "$g" add old.ts
git -C "$g" -c user.email=user@example.com -c user.name=t commit -q -m base; base="$(git -C "$g" rev-parse HEAD)"
printf 'a\nB\nc\n' > "$g/old.ts"; printf 'x\ny\n' > "$g/new.ts"; echo note > "$g/.fxa-todo.md"
check "diffstat: tracked and new files, no scratch" '{"type":"fxa_diffstat","files":[{"file":"old.ts","added":2,"removed":1},{"file":"new.ts","added":2,"removed":0}]}' \
  "$(cd "$g" && bash -c "$_SESSION_DIFFSTAT_SH" _ "$base")"
check "diffstat: the watch turns it into a live event" '{"type":"diffstat","files":[{"file":"a.ts","added":3,"removed":1}]}' \
  "$(echo '{"type":"fxa_diffstat","files":[{"file":"a.ts","added":3,"removed":1}]}' | jq -R -c "$_SESSION_WATCH_JQ")"

# A later session gets the media of every session in the thread: newest first, one per name, up to the cap.
( SESSION_DIR="$tmp/pm"; mkdir -p "$SESSION_DIR/agent-pm1.media" "$SESSION_DIR/agent-pm2.media" "$tmp/pmout" "$tmp/pmcap"
  thread_set C1:1.000001 sessions "agent-pm1 agent-pm2"
  printf 'old' > "$SESSION_DIR/agent-pm1.media/shot.png"; touch -t 202610010000 "$SESSION_DIR/agent-pm1.media/shot.png"
  head -c 4096 /dev/urandom > "$SESSION_DIR/agent-pm1.media/flow.mp4"; touch -t 202610010000 "$SESSION_DIR/agent-pm1.media/flow.mp4"
  printf 'new' > "$SESSION_DIR/agent-pm2.media/shot.png"; printf 'b' > "$SESSION_DIR/agent-pm2.media/after.png"
  _session_pack_media C1:1.000001 "$tmp/pm1.tgz"; tar -xzf "$tmp/pm1.tgz" -C "$tmp/pmout"
  _session_pack_media C2:2.000002 "$tmp/pm2.tgz"; _session_pack_media "" "$tmp/pm3.tgz"
  FXA_RESUME_MEDIA_KB=8 _session_pack_media C1:1.000001 "$tmp/pm4.tgz"; tar -xzf "$tmp/pm4.tgz" -C "$tmp/pmcap"
  check "thread media: all sessions, newest name wins, the cap keeps the newest, none for an empty thread" \
    "after.png flow.mp4 shot.png|new|after.png shot.png|no no" \
    "$(ls "$tmp/pmout" | tr '\n' ' ' | sed 's/ $//')|$(cat "$tmp/pmout/shot.png")|$(ls "$tmp/pmcap" | tr '\n' ' ' | sed 's/ $//')|$([ -e "$tmp/pm2.tgz" ] && printf yes || printf no) $([ -e "$tmp/pm3.tgz" ] && printf yes || printf no)"
  # As the boot runs it: a session with no media folder must not end the boot.
  thread_set C3:3.000003 sessions "agent-pm1 agent-pm9"
  check "thread media: a session with no media is not an error under set -e and pipefail" "0" \
    "$( (set -eo pipefail; _session_pack_media C3:3.000003 "$tmp/pm5.tgz"; echo 0) 2>/dev/null)"  # no || here: it turns set -e off
  exit "$fail" ) || fail=1

# session_boots: recent boots with their slow steps (4 s or more), newest last, and the median.
now_s=$(date +%s)
printf '{"key":"agent-bt01","profile":"fxa","boot_backend":"firecracker","booted_at":"%s","boot_s":"45.2","boot_steps":"[{\\"step\\":\\"restoring\\",\\"s\\":3},{\\"step\\":\\"checking out the commit\\",\\"s\\":36.1}]"}' "$(( now_s - 7200 ))" > "$tmp/agent-bt01.json"
printf '{"key":"agent-bt02","profile":"monitor","boot_backend":"firecracker","booted_at":"%s","boot_s":"12.5","boot_steps":[{"step":"restoring","s":2.8}]}' "$(( now_s - 3600 ))" > "$tmp/agent-bt02.json"
printf '{"key":"agent-bt03","booted_at":"%s","boot_s":"99"}' "$(( now_s - 9 * 86400 ))" > "$tmp/agent-bt03.json"
b="$(session_boots 2 2>&1)"
check "session boots lists the window's boots, with each slow step and the median" "1|1|0|0|1" \
  "$(grep -c 'agent-bt01 fxa firecracker 45.2s' <<< "$b")|$(grep -c '^  checking out the commit 36.1s' <<< "$b")|$(grep -c 'restoring' <<< "$b")|$(grep -c agent-bt03 <<< "$b")|$(grep -c '^median 45.2s over 2 boots' <<< "$b")"
check "session boots refuses a day count that is not a number" "1" "$(session_boots x >/dev/null 2>&1; echo $?)"
rm -f "$tmp"/agent-bt0*.json

exit "$fail"
