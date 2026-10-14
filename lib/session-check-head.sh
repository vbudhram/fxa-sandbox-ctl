#!/usr/bin/env bash
# The shared start of the session checks (session*.check.sh): the session library, a scratch
# folder, and the controller functions they test. Sourced, not run.
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
source "$(dirname "$0")/config.sh"
export FXA_SESSION_STORE_URI="" FXA_SESSION_BACKUP_URI=""  # no bucket unless a check stubs gcloud
FXA_SESSION_DIR="$tmp" source "$(dirname "$0")/session.sh"

eval "$(sed -n '/^worktree_filtered_status() {/,/^}/p;/^worktree_branch_for() {/,/^}/p' "$(dirname "$0")/worktree.sh")"
_worktree_pull_if_remote() { :; }
worktree_git_ok() { :; }
_retry() { "$@"; }  # the scratch repo has no origin: no 3 s + 9 s backoff for each fetch
g() { git -c init.defaultBranch=main -c core.hooksPath=/dev/null "$@"; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
eval "$(sed -n '/^cmd_events() {/,/^}/p;/^cmd_diff() {/,/^}/p;/^_session_key() {/,/^}/p' "$(dirname "$0")/../fxa-sandbox-ctl")"
eval "$(sed -n '/^_session_announce() {/,/^}/p' "$(dirname "$0")/../fxa-sandbox-ctl")"
trees_on() { return 1; }
_session_key() { :; }
eval "$(sed -n '/^_snapshot_session_row() {/,/^}/p' "$(dirname "$0")/snapshot.sh")"
runtime_skill_ref() { printf '/%s' "$1"; }
fin() { jq -nc --arg t "$1" '{type: "result", result: $t}' | _session_parse; }
eval "$(sed -n '/^_session_finish_fail() {/,/^}/p' "$(dirname "$0")/../fxa-sandbox-ctl")"
eval "$(sed -n '/^_finish_session() {/,/^}/p' "$(dirname "$0")/../fxa-sandbox-ctl")"
eval "$(sed -n '/^cmd_task() {/,/^}/p' "$(dirname "$0")/../fxa-sandbox-ctl")"
eval "$(sed -n '/^_task_carry() {/,/^}/p' "$(dirname "$0")/../fxa-sandbox-ctl")"
eval "$(sed -n '/^_checkout_gate_on() {/,/^}/p' "$(dirname "$0")/../fxa-sandbox-ctl")"
eval "$(sed -n '/^trees_from_get() {/,/^}/p' "$(dirname "$0")/trees.sh")"
eval "$(sed -n '/^_task_open_pr() {/,/^}/p' "$(dirname "$0")/../fxa-sandbox-ctl")"
eval "$(grep '^_task_abort()' "$(dirname "$0")/../fxa-sandbox-ctl")"
trees_on() { return 1; }
eval "$(sed -n '/^_task_checkout() {/,/^}/p' "$(dirname "$0")/../fxa-sandbox-ctl")"
eval "$(sed -n '/^_cmd_session_finish() {/,/^}/p' "$(dirname "$0")/../fxa-sandbox-ctl")"
eval "$(sed -n '/^_session_finish_one() {/,/^}/p' "$(dirname "$0")/../fxa-sandbox-ctl")"
