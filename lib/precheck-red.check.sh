#!/usr/bin/env bash
# Offline check that a done PR's red check wakes one pass, not every pass: the pass can only
# report it, so the same red again is quiet until its head or its failures change.
#   bash lib/precheck-red.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
command -v jq >/dev/null || { echo "skip: needs jq"; exit 0; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^cmd_precheck() {/,/^}/p' "$(dirname "$0")/../fxa-sandbox-ctl")"
PIPE_LOCK_DIR="$tmp/pass.lock" PIPE_STATE_DIR="$tmp" PIPE_NAME=test
_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
pipeline_lock() { :; }; pipeline_unlock() { :; }; db_ingest() { :; }
cmd_reconcile() { :; }; cmd_reap() { :; }; cmd_label() { :; }
jira_done_keys() { echo FXA-7; }; jira_inflight_keys() { :; }; jira_queue_keys() { :; }; jira_keys_in_state() { :; }
pipeline_holding_new() { return 1; }; pipeline_focus_key() { :; }
jira_login_ok() { :; }
gh_feedback() { echo '{}'; }
# The red is not known infra. gh_red_infra writes no cache here, as when it returns early (no
# PIPE_INFRA_CHECKS): the fingerprint must take the head from the drain line.
gh_red_infra() { return 1; }
cmd_drain() { echo "FXA-7 70 RED ok=9 fail=$(cat "$tmp/fails") running=$(cat "$tmp/running") head=$(cat "$tmp/sha")"; }
echo aaa > "$tmp/sha"; echo 1 > "$tmp/fails"; echo 0 > "$tmp/running"
q() { cmd_precheck 2>&1 | head -1 | cut -c1-6; }
check "the first time a done PR is red: the pass wakes" "drain:" "$(q)"
check "the same red on the next pass: quiet" "quiet:" "$(q)"
echo 2 > "$tmp/running"
check "only the running count moved: still quiet" "quiet:" "$(q)"
echo 2 > "$tmp/fails"
check "another check fails on the same head: the pass wakes" "drain:" "$(q)"
echo bbb > "$tmp/sha"
check "a new push that is red again: the pass wakes" "drain:" "$(q)"
cmd_drain() { echo "drain: gh pr list failed (exit 1)" >&2; return 1; }; q >/dev/null
cmd_drain() { echo "FXA-7 70 RED ok=9 fail=$(cat "$tmp/fails") running=0 head=$(cat "$tmp/sha")"; }
check "a failed drain keeps the notes: the same red after it stays quiet" "quiet:" "$(q)"
cmd_drain() { :; }; q >/dev/null
cmd_drain() { echo "FXA-7 70 RED ok=9 fail=$(cat "$tmp/fails") running=0 head=$(cat "$tmp/sha")"; }
check "red, then green, then the same red again: the pass wakes" "drain:" "$(q)"
# A conflict GitHub has not computed again after main moved reads 'CONFLICT?': the same conflict, no new wake.
( gh_conflicts() { echo "source a.ts"; }; rm -f "$tmp"/FXA-8.drain-noted
  cmd_drain() { echo "FXA-8 80 CONFLICT"; }; a="$(q)"
  cmd_drain() { echo "FXA-8 80 CONFLICT? mergeability-uncomputed"; }; b="$(q)"
  cmd_drain() { echo "FXA-8 80 CONFLICT"; }; c="$(q)"
  check "a conflict that flips to uncomputed and back wakes the pass once" "drain:|quiet:|quiet:" "$a|$b|$c" )
# An inflight PR's conflict wakes the pass too; its red stays reconcile's.
( jira_done_keys() { :; }; jira_inflight_keys() { echo FXA-9; }; pipeline_progress() { echo "$1 pr 1"; }; gh_conflicts() { echo "source a.ts"; }
  gh_drain() { echo "FXA-9 90 CONFLICT"; echo "FXA-9 90 RED ok=1 fail=1 running=0 head=x"; }; cmd_drain() { :; }
  out="$(cmd_precheck 2>&1)"
  check "an inflight PR's conflict wakes the pass, and its red does not come from the drain" "1|0" "$(grep -c '^drain: FXA-9 90 CONFLICT' <<< "$out")|$(grep -c 'FXA-9 90 RED' <<< "$out")"
  # The same conflict on the next pass stays quiet; a changed line wakes it again; an hour later it wakes again.
  check "the same conflict again is quiet" "0" "$(cmd_precheck 2>&1 | grep -c '^drain: FXA-9')"
  gh_drain() { echo "FXA-9 91 CONFLICT"; }
  check "a changed drain line (a new PR) wakes the pass" "1" "$(cmd_precheck 2>&1 | grep -c '^drain: FXA-9 91 CONFLICT')"
  check "the same line after the rejudge time wakes it again" "1" "$(FXA_PASS_REJUDGE_S=0 cmd_precheck 2>&1 | grep -c '^drain: FXA-9 91 CONFLICT')"
  exit "$fail" ) || fail=1
# Info lines come after work lines, under one "info:" marker: claude-job.sh routes on the lines above it.
pipeline_focus_key() { echo FXA-1; }; echo ccc > "$tmp/sha"
cmd_precheck > "$tmp/pre" 2>&1
check "work, then the info marker, then the held-back info" "drain|info:|mode: focus FXA-1" "$(cut -c1-5 "$tmp/pre" | sed -n 1,2p | paste -sd'|' -)|$(sed -n 3p "$tmp/pre" | cut -c1-17)"
pipeline_focus_key() { :; }
# gh_drain prints the PR's head commit on a RED line, from the same query.
# A drain stderr line that starts with a path is not a ticket key: it never names a note file, and the pass goes on.
cmd_drain() { echo "/home/fxa/x/lib/github.sh: line 166: printf: write error: Broken pipe" >&2; }
out="$(set -e; cmd_precheck 2>&1)"; rc=$?
check "a path in the drain output is reported as work and does not end the pass" "1|drain: /home/fxa/x/lib/github.sh: line 166: printf: write error: Broken pipe|0" \
  "$rc|$out|$(find "$tmp" -name '*github.sh*' | wc -l | tr -d ' ')"
eval "$(sed -n '/^gh_drain() {/,/^}/p' "$(dirname "$0")/github.sh")"
pipeline_require() { :; }; worktree_branch_for() { echo fxa-31; }; PIPE_REPO_SLUG=mozilla/fxa _GH_ROLLUP_JQ=.
gh() { case "$*" in *headRefOid*) echo "fxa-31 310 OPEN 9 1 0 MERGEABLE 0123456789abcdef0123" ;; *) echo "fxa-31 310 OPEN 9 1 0 MERGEABLE" ;; esac; }
check "gh_drain: a RED line carries the head commit" "FXA-31 310 RED ok=9 fail=1 running=0 head=0123456789ab" "$(gh_drain FXA-31)"
exit "$fail"
