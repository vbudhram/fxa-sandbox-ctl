#!/usr/bin/env bash
# Offline check of the draft PR base (epic i168, D13): a one-repo routine run targets its routine branch,
# a Slack session keeps main.
#   bash lib/finish-base.check.sh
source "$(dirname "$0")/session-check-head.sh"
source "$(dirname "$0")/routines.sh"
BASES="$tmp/bases"
finish() { # finish <record json>   the base finish_push_and_pr got, or the error
  ( echo "$1" > "$SESSION_DIR/agent-fb1.json"; : > "$SESSION_DIR/agent-fb1.finish.log"; : > "$BASES"
    runtime_load() { :; }; sleep() { :; }; _session_turn_running() { return 1; }; errors_record() { :; }
    _session_turn() { :; }; vm_exec() { return 0; }; _session_sh() { echo "handoff check: ok"; }
    session_checkout() { mkdir -p "$2"; }; session_checkout_remove() { :; }
    finish_push_and_pr() { echo "${FXA_WORKTREE_BASE:-}${FXA_FINISH_PR:+ ${FXA_FINISH_PR}}$([ -n "${FXA_PR_DRAFT:-}" ] || echo " regular")" >> "$BASES"; echo https://github.com/o/r/pull/1; }
    _session_finish_notes() { :; }; _session_record_summary() { :; }; _thread_ok() { return 1; }
    _cmd_session_finish agent-fb1 >/dev/null 2>"$tmp/fin.err"
    [ -s "$BASES" ] && cat "$BASES" || grep -o 'has a base branch that is not valid' "$tmp/fin.err" | head -1 )
}
check "a routine run with branch release-1 opens its draft PR on release-1" "release-1" \
  "$(finish '{"key":"agent-fb1","state":"wrapping","runtime":"claude","source":"routine","base":"release-1"}')"
check "a routine set to a regular PR opens one that is not a draft" "main regular" \
  "$(finish '{"key":"agent-fb1","state":"wrapping","runtime":"claude","source":"routine","routine_draft":"false"}')"
check "a Slack session keeps main, whatever its record's base" "main" \
  "$(finish '{"key":"agent-fb1","state":"wrapping","runtime":"claude","source":"slack","base":"trunk"}')"
check "a routine run with no base falls back to main" "main" \
  "$(finish '{"key":"agent-fb1","state":"wrapping","runtime":"claude","source":"routine"}')"
check "a routine run with a base that is not a branch name ships nothing" "has a base branch that is not valid" \
  "$(finish '{"key":"agent-fb1","state":"wrapping","runtime":"claude","source":"routine","base":"x..y"}')"
# A fix run: finish gets the run and the head it booted at. A run that ends 'moved' or 'guard:*' records no operator error.
ffinish() { # ffinish <finish exit> <why in heads.fix>   the env finish got, then the errors recorded
  ( echo '{"key":"agent-fb1","state":"wrapping","runtime":"claude","source":"routine","checkout":"https://github.com/o/r/pull/7","review_pr":"https://github.com/o/r/pull/7","fix_pr":"7","fix_head_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","routine_run":"42"}' > "$SESSION_DIR/agent-fb1.json"
    : > "$SESSION_DIR/agent-fb1.finish.log"; : > "$BASES"
    runtime_load() { :; }; sleep() { :; }; _session_turn_running() { return 1; }; errors_record() { echo "error $2" >> "$BASES"; }
    _session_turn() { :; }; vm_exec() { return 0; }; _session_sh() { echo "handoff check: ok"; }
    session_checkout() { mkdir -p "$2"; }; session_checkout_remove() { :; }; _session_history_add() { :; }
    db_value() { echo "$W"; }
    finish_push_and_pr() { echo "${FXA_APP_COMMIT_FF:-} ${FXA_FIX_HEAD_SHA:0:4} ${FXA_FINISH_PR:-}" >> "$BASES"; return "$RC"; }
    RC="$1" W="$2" _cmd_session_finish agent-fb1 >/dev/null 2>&1
    paste -sd'|' "$BASES" )
}
check "a fix run passes its run and head to finish; moved and guard ends record no error, a failed push does" \
  "42 aaaa https://github.com/o/r/pull/7|42 aaaa https://github.com/o/r/pull/7|42 aaaa https://github.com/o/r/pull/7|error pr_failed" \
  "$(ffinish 3 moved)|$(ffinish 1 guard:lock)|$(ffinish 1 '')"
nfinish() { # nfinish <record json>   the errors recorded when the agent wrote no handoff
  ( echo "$1" > "$SESSION_DIR/agent-fb1.json"; : > "$SESSION_DIR/agent-fb1.finish.log"; : > "$BASES"
    runtime_load() { :; }; sleep() { :; }; _session_turn_running() { return 1; }; errors_record() { echo "error $2" >> "$BASES"; }
    _session_turn() { :; }; vm_exec() { [ "$2" != test ]; }; vm_exec_as_agent() { :; }; _session_history_add() { :; }
    _cmd_session_finish agent-fb1 >/dev/null 2>&1
    cat "$BASES"; echo end )
}
check "no handoff: a routine run records no error, a Slack session still does" "end|error pr_failed end" \
  "$(nfinish '{"key":"agent-fb1","state":"wrapping","runtime":"claude","source":"routine","routine_run":"42"}' | paste -sd' ' -)|$(nfinish '{"key":"agent-fb1","state":"wrapping","runtime":"claude","source":"slack"}' | paste -sd' ' -)"
check "a checked-out PR is the PR finish updates; a session's own PR round still finds its PR by branch" "main https://github.com/o/r/pull/7|main" \
  "$(finish '{"key":"agent-fb1","state":"wrapping","runtime":"claude","source":"slack","checkout":"https://github.com/o/r/pull/7","review_pr":"https://github.com/o/r/pull/7"}')|$(finish '{"key":"agent-fb1","state":"wrapping","runtime":"claude","source":"slack","review_pr":"https://github.com/o/r/pull/7"}')"
# Thread targets: the finish ships the current target's worktree and PR (lib/targets.sh).
tfinish() { # tfinish <record json>   the tree, base and PR finish got
  ( echo "$1" > "$SESSION_DIR/agent-fb1.json"; : > "$SESSION_DIR/agent-fb1.finish.log"; : > "$BASES"
    runtime_load() { :; }; sleep() { :; }; _session_turn_running() { return 1; }; errors_record() { :; }
    _session_turn() { :; }; vm_exec() { return 0; }; _session_sh() { echo "handoff check: ok"; }
    session_checkout() { echo "checkout ${FXA_TREE_PATH:-/workspace}" >> "$BASES"; mkdir -p "$2"; }; session_checkout_remove() { :; }
    _checkout_consent() { echo "asked push ok" >> "$BASES"; return 1; }; _session_dirty_trees() { :; }
    finish_push_and_pr() { echo "${FXA_TREE_PATH:-/workspace} ${FXA_WORKTREE_BASE} ${FXA_FINISH_PR:-new PR}" >> "$BASES"; echo https://github.com/o/r/pull/9; }
    _session_finish_notes() { :; }; _session_record_summary() { :; }; _thread_ok() { return 1; }; _session_history_add() { :; }
    _cmd_session_finish agent-fb1 >/dev/null 2>&1
    paste -sd'|' "$BASES" )
}
p2738=https://github.com/mozilla/syncstorage-rs/pull/2738
check "after a switch to PR 2738, finish updates it from its worktree on master, with no push ok and no new PR" \
  "checkout /home/agent/targets/stor-55|/home/agent/targets/stor-55 master $p2738" \
  "$(tfinish '{"key":"agent-fb1","state":"wrapping","runtime":"claude","source":"slack","branch":"stor-55","checkout":"'"$p2738"'","review_pr":"'"$p2738"'","pr_url":"'"$p2738"'","checkout_person":"1","checkout_admin":"UA1","target_path":"/home/agent/targets/stor-55","target_base":"master","current":1,"targets":[{"branch":"agent-46e5fc"},{"branch":"stor-55"}]}')"
check "the boot target still ships /workspace and its own PR" "checkout /workspace|/workspace main new PR" \
  "$(tfinish '{"key":"agent-fb1","state":"wrapping","runtime":"claude","source":"slack","branch":"agent-46e5fc","target_path":"/workspace","current":0}')"
check "a separate PR (a new agent- target) opens a new PR from its worktree" "checkout /home/agent/targets/agent-x|/home/agent/targets/agent-x main new PR" \
  "$(tfinish '{"key":"agent-fb1","state":"wrapping","runtime":"claude","source":"slack","branch":"agent-x","target_path":"/home/agent/targets/agent-x","target_base":"main"}')"
check "a person's PR from !stack checkout still asks for push ok" "asked push ok" \
  "$(tfinish '{"key":"agent-fb1","state":"wrapping","runtime":"claude","source":"slack","branch":"stor-55","checkout":"'"$p2738"'","review_pr":"'"$p2738"'","checkout_person":"1"}')"
exit "$fail"
