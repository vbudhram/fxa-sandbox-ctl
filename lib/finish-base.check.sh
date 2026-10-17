#!/usr/bin/env bash
# Offline check of the draft PR base (epic i168, D13): a one-repo routine run targets its routine branch,
# a Slack session keeps main.
#   bash lib/finish-base.check.sh
source "$(dirname "$0")/session-check-head.sh"
BASES="$tmp/bases"
finish() { # finish <record json>   the base finish_push_and_pr got, or the error
  ( echo "$1" > "$SESSION_DIR/agent-fb1.json"; : > "$SESSION_DIR/agent-fb1.finish.log"; : > "$BASES"
    runtime_load() { :; }; sleep() { :; }; _session_turn_running() { return 1; }; errors_record() { :; }
    _session_turn() { :; }; vm_exec() { return 0; }; _session_sh() { echo "handoff check: ok"; }
    session_checkout() { mkdir -p "$2"; }; session_checkout_remove() { :; }
    finish_push_and_pr() { echo "${FXA_WORKTREE_BASE:-}" >> "$BASES"; echo https://github.com/o/r/pull/1; }
    _session_finish_notes() { :; }; _session_record_summary() { :; }; _thread_ok() { return 1; }
    _cmd_session_finish agent-fb1 >/dev/null 2>"$tmp/fin.err"
    [ -s "$BASES" ] && cat "$BASES" || grep -o 'has a base branch that is not valid' "$tmp/fin.err" | head -1 )
}
check "a routine run with branch release-1 opens its draft PR on release-1" "release-1" \
  "$(finish '{"key":"agent-fb1","state":"wrapping","runtime":"claude","source":"routine","base":"release-1"}')"
check "a Slack session keeps main, whatever its record's base" "main" \
  "$(finish '{"key":"agent-fb1","state":"wrapping","runtime":"claude","source":"slack","base":"trunk"}')"
check "a routine run with no base falls back to main" "main" \
  "$(finish '{"key":"agent-fb1","state":"wrapping","runtime":"claude","source":"routine"}')"
check "a routine run with a base that is not a branch name ships nothing" "has a base branch that is not valid" \
  "$(finish '{"key":"agent-fb1","state":"wrapping","runtime":"claude","source":"routine","base":"x..y"}')"
exit "$fail"
