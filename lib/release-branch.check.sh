#!/usr/bin/env bash
# Offline check for worktree_release_branch on a throwaway repo. No network.
#   bash lib/release-branch.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}

tmp="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT
export FXA_REPO="$tmp/fxa" LOG_DIR="$tmp/logs"
mkdir -p "$LOG_DIR"
git init -q -b main "$FXA_REPO"
git -C "$FXA_REPO" -c user.email=user@example.com -c user.name=t commit -q --allow-empty -m init
git -C "$FXA_REPO" worktree add -q -b fxa-auto-holding "$tmp/fxa-auto"
git -C "$FXA_REPO" worktree add -q -b fxa-1 "$tmp/fxa-auto-2"
git -C "$FXA_REPO" worktree add -q -b mine "$tmp/fxa-agent"
touch "$tmp/fxa-auto-2/.fxa-auto-prompt.txt"

vm_is_running() { return 1; }
source "$(dirname "$0")/worktree.sh"
head_of() { git -C "$1" symbolic-ref --quiet --short HEAD || echo detached; }

worktree_release_branch fxa-1
check "slot detached" "detached" "$(head_of "$tmp/fxa-auto-2")"
check "branch ref kept" "ok" "$(git -C "$FXA_REPO" show-ref -q refs/heads/fxa-1 && echo ok)"
check "slot files kept" "ok" "$([ -f "$tmp/fxa-auto-2/.fxa-auto-prompt.txt" ] && echo ok)"
check "branch free elsewhere" "fxa-1" "$(git -C "$tmp/fxa-agent" checkout -q fxa-1 && head_of "$tmp/fxa-agent")"

# A branch held by a worktree outside the pool is not the pipeline's to touch.
worktree_release_branch fxa-1
check "non-pool worktree kept" "fxa-1" "$(head_of "$tmp/fxa-agent")"

# A slot whose VM still runs keeps its branch.
git -C "$tmp/fxa-auto" checkout -q -b fxa-2
printf 'NAME=fxa-2\nWORKSPACE=%s\n' "$tmp/fxa-auto" > "$LOG_DIR/fxa-2.meta"
vm_is_running() { [ "$1" = fxa-2 ]; }
worktree_release_branch fxa-2
check "busy slot kept" "fxa-2" "$(head_of "$tmp/fxa-auto")"

exit "$fail"
