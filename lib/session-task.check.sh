#!/usr/bin/env bash
# Offline check for cmd_task: restarts, profiles, threads, retention, notes, the idle pause and the session cap.
#   bash lib/session-task.check.sh
source "$(dirname "$0")/session-check-head.sh"

# The sessions kill switch, with the local marker (no bucket).
_SESSIONS_PAUSE_URI=""
check "not paused at first" "no" "$(sessions_paused >/dev/null && echo yes || echo no)"
sessions_pause "costs are high" >/dev/null
check "paused, with the reason" "costs are high" "$(sessions_paused)"
printf 'hi\n' > "$tmp/p.md"
check "a new session is refused while paused" "agent sessions are paused by the operator: costs are high" \
  "$(FXA_VM_BACKEND=gce cmd_task --source slack --id agent-kill1 --owner U1 --prompt-file "$tmp/p.md" 2>&1 >/dev/null | sed 's/^ERROR: //')"
echo '{"key":"agent-kill2","state":"active","turn_open":"1"}' > "$tmp/agent-kill2.json"
session_stop() { session_set "$1" state stopped; }
sessions_pause "costs are high" --now >/dev/null
check "--now pauses an active session, even mid-turn" "paused" "$(session_get agent-kill2 state)"
sessions_resume >/dev/null
check "resume clears it" "no" "$(sessions_paused >/dev/null && echo yes || echo no)"
check "a Codex session is refused unless the host opts in" "Codex sessions are turned off on this host (FXA_SESSION_CODEX)" \
  "$(FXA_VM_BACKEND=gce cmd_task --source slack --id agent-cdx1 --owner U1 --prompt-file "$tmp/p.md" --runtime codex 2>&1 >/dev/null | sed 's/^ERROR: //')"
check "and no record is written" "no" "$( [ -f "$tmp/agent-cdx1.json" ] && echo yes || echo no)"
# !restart on an open PR: a fresh round on its branch at its head. A closed PR starts from main.
nohup() { :; }; gh() { echo "$GH_STATE"; }
# The record names the profile and its base branch, so later commands load the same one.
PIPE_PROFILE=demo PIPE_BASE_BRANCH=trunk FXA_VM_BACKEND=gce cmd_task --source slack --id agent-prof1 --owner U1 --prompt-file "$tmp/p.md" >/dev/null 2>&1
check "the record names the profile and base" "demo trunk" "$(session_get agent-prof1 profile) $(session_get agent-prof1 base)"
echo '{"key":"agent-prr1","state":"stopped","branch":"agent-prr1","pr_url":"https://github.com/mozilla/fxa/pull/9"}' > "$tmp/agent-prr1.json"
GH_STATE=OPEN FXA_VM_BACKEND=gce cmd_task --source slack --id agent-fre1 --owner U1 --prompt-file "$tmp/p.md" --resume-from agent-prr1 --fresh >/dev/null 2>&1
check "fresh on an open PR keeps its branch and PR" "agent-prr1 https://github.com/mozilla/fxa/pull/9 1 agent-prr1 https://github.com/mozilla/fxa/pull/9" \
  "$(session_get agent-fre1 branch) $(session_get agent-fre1 review_pr) $(session_get agent-fre1 fresh) $(session_get agent-fre1 resume_from) $(session_get agent-fre1 pr_url)"
GH_STATE=CLOSED FXA_VM_BACKEND=gce cmd_task --source slack --id agent-fre2 --owner U1 --prompt-file "$tmp/p.md" --resume-from agent-prr1 --fresh >/dev/null 2>&1
check "fresh on a closed PR starts from main" "agent-fre2||" "$(session_get agent-fre2 branch)|$(session_get agent-fre2 review_pr)|$(session_get agent-fre2 resume_from)"
# A fresh session made before pr_url was kept has only review_pr; !restart again keeps that PR.
echo '{"key":"agent-old7","state":"stopped","branch":"agent-prr1","review_pr":"https://github.com/mozilla/fxa/pull/9"}' > "$tmp/agent-old7.json"
GH_STATE=OPEN FXA_VM_BACKEND=gce FXA_SESSION_MAX=20 cmd_task --source slack --id agent-fre3 --owner U1 --prompt-file "$tmp/p.md" --resume-from agent-old7 --fresh >/dev/null 2>&1
check "a legacy fresh session's PR carries over" "https://github.com/mozilla/fxa/pull/9|https://github.com/mozilla/fxa/pull/9" "$(session_get agent-fre3 review_pr)|$(session_get agent-fre3 pr_url)"
# A paused session whose PR merged resumes without it.
echo '{"key":"agent-mrg1","state":"paused","branch":"agent-mrg1","pr_url":"https://github.com/mozilla/fxa/pull/8"}' > "$tmp/agent-mrg1.json"
GH_STATE=MERGED FXA_VM_BACKEND=gce FXA_SESSION_MAX=20 cmd_task --source slack --id agent-mrg2 --owner U1 --prompt-file "$tmp/p.md" --resume-from agent-mrg1 >/dev/null 2>&1
check "a merged PR is not carried to the resume" "agent-mrg2|" "$(session_get agent-mrg2 branch)|$(session_get agent-mrg2 pr_url)"
# A person's PR taken over with --checkout keeps its consent gate when a reply resumes it.
co=https://github.com/mozilla/fxa/pull/77
echo "{\"key\":\"agent-cox1\",\"state\":\"paused\",\"branch\":\"alice-fix\",\"pr_url\":\"$co\",\"review_pr\":\"$co\",\"checkout\":\"$co\",\"checkout_author\":\"alice\",\"checkout_person\":\"1\"}" > "$tmp/agent-cox1.json"
GH_STATE=OPEN FXA_VM_BACKEND=gce FXA_SESSION_MAX=20 cmd_task --source slack --id agent-cox2 --owner U1 --prompt-file "$tmp/p.md" --resume-from agent-cox1 >/dev/null 2>&1
check "a resumed checkout keeps the author and the gate" "$co alice 1 on" \
  "$(session_get agent-cox2 checkout) $(session_get agent-cox2 checkout_author) $(session_get agent-cox2 checkout_person) $(_checkout_gate_on agent-cox2 && echo on)"
# Paused after its PR with no review_pr: it pushes to the PR's branch, so the gate holds too.
echo "{\"key\":\"agent-cox3\",\"state\":\"paused\",\"branch\":\"alice-fix\",\"pr_url\":\"$co\",\"checkout\":\"$co\",\"checkout_author\":\"alice\",\"checkout_person\":\"1\"}" > "$tmp/agent-cox3.json"
GH_STATE=OPEN FXA_VM_BACKEND=gce FXA_SESSION_MAX=20 cmd_task --source slack --id agent-cox4 --owner U1 --prompt-file "$tmp/p.md" --resume-from agent-cox3 >/dev/null 2>&1
check "a paused checkout with only pr_url keeps the gate" "alice-fix|$co|on" "$(session_get agent-cox4 branch)|$(session_get agent-cox4 pr_url)|$(_checkout_gate_on agent-cox4 && echo on)"
check "a bot's PR has no gate" "off" "$(session_set agent-cox4 checkout_person 0; _checkout_gate_on agent-cox4 || echo off)"
# A fork PR is refused where the checkout starts: its repo's CLAUDE.md and skills would reach the agent.
echo '{"key":"agent-cof1"}' > "$tmp/agent-cof1.json"
check "a fork PR is refused at checkout, and nothing is set" "ERROR: https://github.com/mozilla/fxa/pull/78 is from a fork. Ask for a PR from a branch of mozilla/fxa instead|" \
  "$(gh() { echo '{"state":"OPEN","headRefName":"fix","isCrossRepository":true,"author":{"login":"bob","is_bot":false}}'; }; PIPE_REPO_SLUG=mozilla/fxa _task_checkout agent-cof1 https://github.com/mozilla/fxa/pull/78 2>&1)|$(session_get agent-cof1 checkout)"
check "a same-repo PR is taken, with its author's gate" "fix https://github.com/mozilla/fxa/pull/79 alice 1" \
  "$(gh() { echo '{"state":"OPEN","headRefName":"fix","isCrossRepository":false,"author":{"login":"alice","is_bot":false}}'; }; PIPE_REPO_SLUG=mozilla/fxa _task_checkout agent-cof1 https://github.com/mozilla/fxa/pull/79 >/dev/null 2>&1; echo "$(session_get agent-cof1 branch) $(session_get agent-cof1 checkout) $(session_get agent-cof1 checkout_author) $(session_get agent-cof1 checkout_person)")"
# The thread record: the first request, its sessions, and its open PR for later sessions.
export FXA_SESSION_MAX=20 # the earlier checks left sessions live
printf 'Build the tests\n\nEarlier messages in this Slack thread, for context:\n> owner: hi\n' > "$tmp/t.md"
th="C0AB:1790805741.326109"
FXA_VM_BACKEND=gce cmd_task --source slack --id agent-thr1 --owner U1 --prompt-file "$tmp/t.md" --thread "$th" >/dev/null 2>&1
check "the thread keeps the first request and its sessions" "Build the tests|agent-thr1|$th" "$(thread_get "$th" request | head -1)|$(thread_get "$th" sessions)|$(session_get agent-thr1 thread)"
# Retention: an old, not live session goes with all its files and its thread; a live or recent one stays.
mkdir -p "$tmp/rt" "$tmp/rt/mcp/tokens"; old=$(( $(date +%s) - 40 * 86400 ))
echo "{\"key\":\"agent-ret1\",\"state\":\"paused\",\"last_activity\":$old}" > "$tmp/rt/agent-ret1.json"
touch "$tmp/rt/agent-ret1.prompt.md" "$tmp/rt/agent-ret1.claude.tgz"; mkdir -p "$tmp/rt/agent-ret1.run"
echo "{\"key\":\"agent-ret2\",\"state\":\"active\",\"last_activity\":$old}" > "$tmp/rt/agent-ret2.json"
echo "{\"key\":\"agent-ret3\",\"state\":\"stopped\",\"last_activity\":$(date +%s)}" > "$tmp/rt/agent-ret3.json"
echo '{"sessions":"agent-ret1"}' > "$tmp/rt/thread-C0AB-1.1.json"; touch "$tmp/rt/thread-C0AB-1.1.notes.md"
echo '{"sessions":"agent-ret1 agent-ret3"}' > "$tmp/rt/thread-C0AB-2.2.json"
# The gateway writes ISO times; numbers too, as older lines did.
printf '%s\n' "{\"at\":$old,\"args\":\"old\"}" "{\"at\":$(date +%s),\"args\":\"new\"}" \
  "{\"at\":\"$(jq -rn --argjson t "$old" '$t | todate')\",\"args\":\"old-iso\"}" "{\"at\":\"$(date -u +%FT%TZ)\",\"args\":\"new-iso\"}" > "$tmp/rt/mcp/calls.jsonl"
touch "$tmp/rt/mcp/tokens/fxm_new"
out="$(SESSION_DIR="$tmp/rt" FXA_MCP_GATEWAY_DIR="$tmp/rt/mcp" FXA_LLM_PROXY_DIR="$tmp/rt/none" session_prune)"
check "prune deletes the old session's files and prints its key" "agent-ret1|0" "$out|$(ls "$tmp/rt" | grep -c '^agent-ret1')"
check "prune keeps a live session and a recent one" "yes yes" "$([ -f "$tmp/rt/agent-ret2.json" ] && echo yes) $([ -f "$tmp/rt/agent-ret3.json" ] && echo yes)"
check "prune deletes a thread no session uses, keeps one still in use" "no yes" "$([ -f "$tmp/rt/thread-C0AB-1.1.json" ] || [ -f "$tmp/rt/thread-C0AB-1.1.notes.md" ] && echo yes || echo no) $([ -f "$tmp/rt/thread-C0AB-2.2.json" ] && echo yes)"
check "prune drops old MCP call lines and keeps new tokens" "new,new-iso|yes" "$(jq -r .args "$tmp/rt/mcp/calls.jsonl" | paste -sd, -)|$([ -f "$tmp/rt/mcp/tokens/fxm_new" ] && echo yes)"
check "a new thread's task runs under set -e" "agent-thr4 starting" \
  "$(set -e; nohup() { :; }; FXA_VM_BACKEND=gce cmd_task --source slack --id agent-thr4 --owner U1 --prompt-file "$tmp/t.md" --thread C0AB:1790000000.000001 2>/dev/null)"
check "a bad thread id is refused" "--thread must look like C0123:1790000000.000100" \
  "$(FXA_VM_BACKEND=gce cmd_task --source slack --id agent-thr9 --owner U1 --prompt-file "$tmp/t.md" --thread 'x;y' 2>&1 >/dev/null | sed 's/^ERROR: //')"
thread_set "$th" pr_url https://github.com/mozilla/fxa/pull/9 pr_session agent-prr1
GH_STATE=OPEN FXA_VM_BACKEND=gce cmd_task --source slack --id agent-thr2 --owner U1 --prompt-file "$tmp/p.md" --thread "$th" >/dev/null 2>&1
check "a later session in the thread gets its open PR" "agent-prr1 https://github.com/mozilla/fxa/pull/9 1|agent-thr1 agent-thr2|Build the tests" \
  "$(session_get agent-thr2 branch) $(session_get agent-thr2 review_pr) $(session_get agent-thr2 fresh)|$(thread_get "$th" sessions)|$(thread_get "$th" request | head -1)"
GH_STATE=OPEN FXA_VM_BACKEND=gce cmd_task --source slack --id agent-thr3 --owner U1 --prompt-file "$tmp/p.md" --thread "$th" --new >/dev/null 2>&1
check "!new starts from main" "agent-thr3||1" "$(session_get agent-thr3 branch)|$(session_get agent-thr3 review_pr)|$(session_get agent-thr3 new)"
unset -f nohup gh

# Notes: saved when the turn changed them; stale when it did not.
printf 'goal: tests\n' > "$tmp/n1"
_thread_save_notes agent-thr1 "$tmp/n1"
check "changed notes are saved" "goal: tests|0" "$(cat "$(_thread_notes "$th")")|$(session_get agent-thr1 notes_stale)"
_thread_save_notes agent-thr1 "$tmp/n1"
check "unchanged notes are stale" "1" "$(session_get agent-thr1 notes_stale)"
: > "$tmp/n0"; _thread_save_notes agent-thr1 "$tmp/n0"
check "empty notes keep the saved ones" "goal: tests|1" "$(cat "$(_thread_notes "$th")")|$(session_get agent-thr1 notes_stale)"

# The pause: stale notes get one quiet handoff turn first, then the next sweep pauses at once.
_session_turn() { [ "${3:-}" = quiet ] && session_set "$1" handoff running handoff_at "$(date +%s)"; }
_session_sh() { return 1; } # the handoff's claude is gone
_session_desktop_in_use() { return 1; }
session_stop() { session_set "$1" state stopped; }
for k in agent-thr1 agent-thr2 agent-thr3 agent-fre1 agent-fre2; do session_set "$k" state stopped; done
session_set agent-thr1 state active turn_open 0 notes_stale 1 runtime claude
jq '.last_activity = 0' "$tmp/agent-thr1.json" > "$tmp/x" && mv "$tmp/x" "$tmp/agent-thr1.json"
check "stale notes: a handoff, no pause yet" "handoff agent-thr1|active|running" "$(session_idle_sweep 2>/dev/null | grep -v '^stopped ')|$(session_get agent-thr1 state)|$(session_get agent-thr1 handoff)"
check "after the handoff it pauses at once" "paused agent-thr1|paused" "$(session_idle_sweep 2>/dev/null | grep -v '^stopped ')|$(session_get agent-thr1 state)"
_session_turn() { return 1; } # the handoff cannot start
session_set agent-thr1 state active handoff "" notes_stale 1
jq '.last_activity = 0' "$tmp/agent-thr1.json" > "$tmp/x" && mv "$tmp/x" "$tmp/agent-thr1.json"
session_idle_sweep >/dev/null 2>&1
check "a handoff that cannot start does not hold the pause off" "paused agent-thr1" "$(session_idle_sweep 2>/dev/null | grep -v '^stopped ')"
# A test the agent left running in the background holds the pause off; none, and it pauses.
session_set agent-thr1 state active handoff done notes_stale 0
jq '.last_activity = 0' "$tmp/agent-thr1.json" > "$tmp/x" && mv "$tmp/x" "$tmp/agent-thr1.json"
_session_sh() { case "$2" in *laywright*) return 0 ;; *) return 1 ;; esac; }
check "a running test run keeps it up" "|active" "$(session_idle_sweep 2>/dev/null | grep -v '^stopped ')|$(session_get agent-thr1 state)"
session_set agent-thr1 handoff done
jq '.last_activity = 0' "$tmp/agent-thr1.json" > "$tmp/x" && mv "$tmp/x" "$tmp/agent-thr1.json"
_session_sh() { return 1; }
check "with no run left it pauses" "paused agent-thr1" "$(session_idle_sweep 2>/dev/null | grep -v '^stopped ')"

# The cap: two requests at once with one slot left start one session, not two. A slow cap read
# holds both between the count and the record, where the race was.
nohup() { :; }; n_live=0
for f in "$tmp"/agent-*.json; do [ -f "$f" ] && session_live "$(basename "$f" .json)" && n_live=$(( n_live + 1 )); done
( _session_cap() { sleep 1; echo $(( n_live + 1 )); }
  for k in agent-cap1 agent-cap2; do FXA_VM_BACKEND=gce cmd_task --source slack --id "$k" --owner U1 --prompt-file "$tmp/p.md" > "$tmp/$k.out" 2>&1 & done; wait )
check "two requests for the last slot: one starts, one is refused at the cap" "1|1" \
  "$(ls "$tmp"/agent-cap[12].json 2>/dev/null | wc -l | tr -d ' ')|$(cat "$tmp"/agent-cap[12].out | grep -c 'cap ')"
rm -f "$tmp"/agent-cap*

exit "$fail"
