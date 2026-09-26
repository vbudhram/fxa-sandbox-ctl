#!/usr/bin/env bash
# Offline check that a launch never uses a worktree outside the pool, and that
# resuming a diverged branch never resets over uncommitted edits.
#   bash lib/launch-slot.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}

tmp="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT
here="$(cd "$(dirname "$0")" && pwd -P)"
eval "$(sed -n '/^worktree_branch_for() {/,/^}/p;/^worktree_filtered_status() {/,/^}/p;/^_worktree_sync_to_origin() {/,/^}/p' "$here/worktree.sh")"
eval "$(sed -n '/^_launch_slot_for() {/,/^}/p' "$here/../fxa-sandbox-ctl")"
_worktree_pull_if_remote() { :; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
g() { git -c init.defaultBranch=main -c core.hooksPath=/dev/null "$@"; }

g init -q --bare "$tmp/origin.git"
g clone -q "$tmp/origin.git" "$tmp/fxa" 2>/dev/null
cd "$tmp/fxa"
printf 'base\n' >a.txt; g add .; g commit -qm base; g push -q origin main
for b in fxa-1 fxa-2 fxa-3; do g branch -q "$b"; g push -q origin "$b"; done
g worktree add -q "$tmp/fxa-auto-2" fxa-1
g worktree add -q "$tmp/fxa-agent" fxa-2
PIPE_REPO="$tmp/fxa"
_worktree_pool_list() { printf '%s\n' "$tmp/fxa-auto" "$tmp/fxa-auto-2"; }

check "unheld branch keeps the named slot" "fxa-auto" "$(_launch_slot_for FXA-3 fxa-auto 2>/dev/null)"
check "branch in a pool slot moves there" "fxa-auto-2" "$(_launch_slot_for FXA-1 fxa-auto 2>/dev/null)"
_launch_slot_for FXA-2 fxa-auto >/dev/null 2>&1; rc=$?
check "branch outside the pool is refused" "1" "$rc"
check "refusal names the worktree" "yes" "$(_launch_slot_for FXA-2 fxa-auto 2>&1 | grep -q "$tmp/fxa-agent" && echo yes)"

# Diverge fxa-1: origin moves on, the slot has its own commit.
g clone -q "$tmp/origin.git" "$tmp/other" 2>/dev/null
g -C "$tmp/other" checkout -q fxa-1; printf 'remote\n' >"$tmp/other/b.txt"
g -C "$tmp/other" add .; g -C "$tmp/other" commit -qm remote; g -C "$tmp/other" push -q origin fxa-1
printf 'local\n' >"$tmp/fxa-auto-2/c.txt"; g -C "$tmp/fxa-auto-2" add .; g -C "$tmp/fxa-auto-2" commit -qm local
printf 'unsaved edit\n' >>"$tmp/fxa-auto-2/a.txt"

_worktree_sync_to_origin "$tmp/fxa-auto-2" fxa-1 >/dev/null 2>&1; rc=$?
check "dirty diverged worktree is refused" "1" "$rc"
check "uncommitted edit survives" "yes" "$(grep -q 'unsaved edit' "$tmp/fxa-auto-2/a.txt" && echo yes)"

g -C "$tmp/fxa-auto-2" checkout -q -- a.txt
_worktree_sync_to_origin "$tmp/fxa-auto-2" fxa-1 >/dev/null 2>&1; rc=$?
check "clean diverged worktree still resets" "0" "$rc"
check "reset lands on origin" "$(g -C "$tmp/fxa" rev-parse origin/fxa-1 2>/dev/null || g -C "$tmp/other" rev-parse HEAD)" "$(g -C "$tmp/fxa-auto-2" rev-parse HEAD)"

exit "$fail"
