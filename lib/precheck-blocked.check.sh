#!/usr/bin/env bash
# Offline check that precheck moves a blocked ticket whose PR a person merged or closed.
#   bash lib/precheck-blocked.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
command -v jq >/dev/null || { echo "skip: needs jq"; exit 0; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^cmd_precheck() {/,/^}/p' "$(dirname "$0")/../fxa-sandbox-ctl")"
PIPE_LOCK_DIR="$tmp/pass.lock" PIPE_STATE_DIR="$tmp"
pipeline_lock() { :; }; pipeline_unlock() { :; }; db_ingest() { :; }
cmd_reconcile() { :; }; cmd_drain() { :; }; cmd_reap() { :; }
jira_done_keys() { :; }; jira_inflight_keys() { :; }; jira_queue_keys() { :; }
pipeline_holding_new() { return 1; }; pipeline_focus_key() { :; }
jira_login_ok() { :; }
jira_keys_in_state() { [ "$1" = blocked ] && printf 'FXA-1\nFXA-2\nFXA-3\n'; }
gh_pr_state() { case "$1" in FXA-1) echo "FXA-1 11 MERGED ok=1";; FXA-2) echo "FXA-2 12 CLOSED ok=1";; *) echo "FXA-3 13 OPEN ok=1";; esac; }
cmd_label() { echo "$1 $2" >> "$tmp/labels"; }
out="$(cmd_precheck 2>&1)"
check "a merged PR moves the ticket to merged, a closed one to rejected, an open one stays" "FXA-1 merged|FXA-2 rejected" "$(paste -sd'|' "$tmp/labels")"
check "the quiet line counts them" "yes" "$(grep -q '1 merged, 1 rejected' <<<"$out" && echo yes)"
# A secret team: its repo gate runs once in the pass's own shell; a repo not confirmed private stops the pass.
: > "$tmp/labels"; errors_record() { echo "$5" >> "$tmp/errors"; }
pipeline_jira_scope() { echo x >> "$tmp/scope"; [ -z "${GATE_FAIL:-}" ] || { echo "ERROR: fxa-private: mozilla/fxa-private is not confirmed private" >&2; return 1; }; G_OK=1; echo scope; }
cmd_reconcile() { echo r >> "$tmp/rec"; }
out="$(PIPE_SECRET_TICKETS=1 PIPE_PROFILE=fxa-private GATE_FAIL=1 cmd_precheck 2>&1)"
check "a secret team whose repo is not confirmed private pauses before any read, with one error row" "paused: team fxa-private's work repo is not confirmed private; see errors (pipeline/private)|0|1|0" \
  "$out|$(cat "$tmp/rec" 2>/dev/null | grep -c .)|$(grep -c 'not confirmed private' "$tmp/errors")|$(grep -c . "$tmp/labels")"
: > "$tmp/scope"
check "with the repo confirmed, the gate ran in the pass's shell (its yes reaches the reads below)" "1" \
  "$( (PIPE_SECRET_TICKETS=1 PIPE_PROFILE=fxa-private cmd_precheck >/dev/null 2>&1; echo "${G_OK:-0}") )"

# A PR blocked for its review rounds or fix attempts still gets rebases; other blocked kinds do not.
: > "$tmp/labels"; _FXA_REBASE_CAP=5; pipeline_rebasing() { return 1; }; pipeline_rebases() { echo 0; }; PIPE_REPO_SLUG=mozilla/fxa PIPE_NAME=test
_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
jira_keys_in_state() { [ "$1" = blocked ] && printf 'FXA-4\nFXA-5\nFXA-6\nFXA-7\n'; }
gh_pr_state() { echo "$1 ${1#FXA-} OPEN ok=1"; }
printf '1\trounds\t\n' > "$tmp/FXA-4.blocked-why"; printf '1\tattempts\t\n' > "$tmp/FXA-5.blocked-why"
printf '1\tstalled\t\n' > "$tmp/FXA-6.blocked-why"; printf '1\tattempts\t\n' > "$tmp/FXA-7.blocked-why"
gh() { echo "$*" >> "$tmp/gh"; case "$*" in *" 4 "*|*" 5 "*) echo "CONFLICTING DIRTY" ;; *" 7 "*) echo "MERGEABLE BEHIND" ;; *) echo "MERGEABLE CLEAN" ;; esac; }
gh_conflicts() { case "$1" in FXA-4) echo "source a.ts" ;; *) echo "lockfile yarn.lock" ;; esac; }
gh_relock() { echo "$1" >> "$tmp/relocked"; }; gh_update_branch() { echo "$1" >> "$tmp/updated"; }; gh_pr_approved() { :; }
out="$(cmd_precheck 2>&1)"
check "blocked rounds with a source conflict wakes the pass, a red blocked attempts lockfile is relocked, blocked stalled is not read" \
  "1|FXA-5|0|7" "$(grep -c 'drain: FXA-4 4 CONFLICT blocked:rounds' <<< "$out")|$(cat "$tmp/relocked")|$(grep -c ' 6 ' "$tmp/gh")|$(cat "$tmp/updated")"
check "the labels and the blocked reasons stay" "0|rounds" "$(grep -c . "$tmp/labels")|$(cut -f2 "$tmp/FXA-4.blocked-why")"
check "the same blocked conflict on the next precheck is quiet" "0" "$(cmd_precheck 2>&1 | grep -c 'drain: FXA-4 4 CONFLICT blocked')"
pipeline_rebases() { echo 5; }
check "a blocked PR at 5 rebases does not wake, and is not labelled again" "0|0" "$(rm -f "$tmp/FXA-4.drain-noted"; cmd_precheck 2>&1 | grep -c '^drain: FXA-4')|$(grep -c . "$tmp/labels")"

# A team admin's new comment on a blocked PR wakes the pass for a round, once; another commenter's never does.
gh_admin_logins() { echo member-a; }
jira_keys_in_state() { [ "$1" = blocked ] && printf 'FXA-8\nFXA-9\n'; }
printf '1\tlaunch_error\tERROR: x\n' > "$tmp/FXA-8.blocked-why"; printf '1\trounds\t\n' > "$tmp/FXA-9.blocked-why"
gh_feedback() { case "$1" in
  FXA-8) echo '{"pr":8,"comments":[{"id":"i1","author":"member-a","admin":true},{"id":"2","author":"Copilot","admin":false}]}' ;;
  *) echo '{"pr":9,"comments":[{"id":"i3","author":"stranger","admin":false}]}' ;; esac; }
out="$(cmd_precheck 2>&1)"
check "a blocked PR with an admin comment wakes the pass with only that id; a stranger's comment does not" "1|0" \
  "$(grep -c '^feedback: FXA-8 is blocked, and a team admin left new comments: i1 (run: feedback FXA-8 bundle)' <<< "$out")|$(grep -c 'FXA-9 is blocked' <<< "$out")"
check "the same admin comment on the next precheck is quiet" "0" "$(cmd_precheck 2>&1 | grep -c '^feedback: FXA-8')"
# The admin wake stops at the team's admin round cap; below it, the comment still wakes.
gh_feedback() { case "${2:-}" in admin-rounds) echo "${ADMIN_N:-0}" ;; *) echo '{"pr":8,"comments":[{"id":"i1","author":"member-a","admin":true}]}' ;; esac; }
jira_keys_in_state() { [ "$1" = blocked ] && echo FXA-8; }
rm -f "$tmp/FXA-8.feedback-noted"
check "an admin comment does not wake the pass at 10 admin rounds, or at the team's 3" "0|0" \
  "$(ADMIN_N=10 cmd_precheck 2>&1 | grep -c '^feedback: FXA-8')|$(ADMIN_N=3 PIPE_ADMIN_REVIEW_ROUNDS=3 cmd_precheck 2>&1 | grep -c '^feedback: FXA-8')"
check "below the cap it wakes" "1" "$(ADMIN_N=9 cmd_precheck 2>&1 | grep -c '^feedback: FXA-8')"
gh_admin_logins() { :; }; rm -f "$tmp/FXA-8.feedback-noted"
check "with no admin logins, no blocked PR is read for feedback" "0" "$(cmd_precheck 2>&1 | grep -c '^feedback:')"

[ "$fail" = 0 ] && echo "all ok"
exit "$fail"
