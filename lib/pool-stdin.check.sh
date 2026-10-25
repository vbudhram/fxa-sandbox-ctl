#!/usr/bin/env bash
# Offline check that the pool and free-slot loops see every slot while a runner is up: the runner
# check (ssh to a Firecracker runner, or gcloud) must not read the loop's list of slots.
#   bash lib/pool-stdin.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
here="$(cd "$(dirname "$0")" && pwd)"
eval "$(sed -n '/^_worktree_each_active_agent() {/,/^}/p;/^_worktree_agent_for_workspace() {/,/^}/p;/^worktree_free_slots() {/,/^}/p;/^worktree_finishing() {/,/^}/p' "$here/worktree.sh")"
# Three slots; a runner works in slot 1. The runner check reads stdin, as ssh does.
LOG_DIR="$tmp"; printf 'NAME=fxa-1\nWORKSPACE=%s/p/s1\n' "$tmp" > "$tmp/fxa-1.meta"
vm_is_running() { cat > /dev/null; return 0; }
worktree_repo_root() { echo "$tmp/p/fxa"; }
worktree_pool_slot_names() { printf 's1\ns2\ns3\n'; }
worktree_key_for() { echo "$1"; }; worktree_filtered_status() { :; }
mkdir -p "$tmp/p/s1" "$tmp/p/s2" "$tmp/p/s3"
git() { echo HEAD; }
check "with a runner up in slot 1, slots 2 and 3 are still seen as free" "s2 s3" "$(FXA_VM_BACKEND=gce worktree_free_slots "" | paste -sd' ' -)"
exit "$fail"
