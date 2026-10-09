#!/usr/bin/env bash
# Offline check for worktree_free_slots: which pool slots another ticket may take.
#   bash lib/worktree-free.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
here="$(cd "$(dirname "$0")" && pwd)"
eval "$(sed -n '/^worktree_free_slots() {/,/^}/p' "$here/worktree.sh")"
eval "$(sed -n '/^worktree_key_for() {/,/^}/p' "$here/worktree.sh")"
eval "$(sed -n '/^worktree_filtered_status() {/,/^}/p' "$here/worktree.sh")"
worktree_repo_root() { echo "$tmp/fxa"; }
worktree_pool_slot_names() { printf 'fxa-auto-1\nfxa-auto-2\n'; }
_worktree_agent_for_workspace() { :; }; _worktree_pull_if_remote() { :; }; worktree_git_ok() { :; }
for s in fxa-auto-1 fxa-auto-2; do
  git init -q "$tmp/$s" && git -C "$tmp/$s" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
  echo '{}' > "$tmp/$s/package.json"; git -C "$tmp/$s" add package.json
  git -C "$tmp/$s" -c user.email=t@example.com -c user.name=t commit -q -m pkg
done
git -C "$tmp/fxa-auto-1" checkout -q -b fxa-14727; git -C "$tmp/fxa-auto-2" checkout -q -b fxa-14580
check "clean idle slots are free" "fxa-auto-1 fxa-auto-2" "$(FXA_VM_BACKEND=gce worktree_free_slots "" | tr '\n' ' ' | sed 's/ $//')"
echo '{"a":1}' > "$tmp/fxa-auto-1/package.json"; git -C "$tmp/fxa-auto-1" add package.json
check "a slot with a staged, unshipped change is not free" "fxa-auto-2" "$(FXA_VM_BACKEND=gce worktree_free_slots "" | tr '\n' ' ' | sed 's/ $//')"
# A ticket that leaves inflight: its unshipped changes are saved, and its slot goes back to the pool.
eval "$(sed -n '/^worktree_release_branch() {/,/^}/p' "$here/worktree.sh")"
_worktree_pool_list() { printf '%s\n' "$tmp/fxa-auto-1" "$tmp/fxa-auto-2"; }
PIPE_STATE_DIR="$tmp/state"; mkdir -p "$PIPE_STATE_DIR"
echo new > "$tmp/fxa-auto-1/notes.txt"
worktree_release_branch fxa-14727 >/dev/null 2>&1
check "the release saves the staged and the new file, then frees the slot" "1|1|1|fxa-auto-1 fxa-auto-2" \
  "$(grep -c '"a":1' "$PIPE_STATE_DIR"/FXA-14727.leftover-*.patch)|$(grep -c '^+new$' "$PIPE_STATE_DIR"/FXA-14727.leftover-*.patch)|$(git -C "$tmp/fxa-auto-1" rev-parse --abbrev-ref HEAD | grep -cx HEAD)|$(FXA_VM_BACKEND=gce worktree_free_slots "" | tr '\n' ' ' | sed 's/ $//')"
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
