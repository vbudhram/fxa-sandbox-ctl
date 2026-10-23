#!/usr/bin/env bash
# tail-key.check.sh: `tail` takes a Jira key as well as the agent name; the pass passes the key.
#   Checks cmd_tail in fxa-sandbox-ctl.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
fail=0; check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; fail=1; fi; }
LOG_DIR="$(mktemp -d)"; trap 'rm -rf "$LOG_DIR"' EXIT
eval "$(sed -n '/^cmd_tail() {/,/^}/p' "$root/fxa-sandbox-ctl")"
eval "$(sed -n '/^worktree_branch_for() {/,/^}/p' "$root/lib/worktree.sh")"
ssh() { echo "ssh to ${@: -2:1}"; }; VM_SSH_OPTS="" VM_SSH_USER=agent VM_SCREEN_SESSION=s
printf 'NAME=fxa-14822\nIP=10.0.0.9\n' > "$LOG_DIR/fxa-14822.meta"; : > "$LOG_DIR/other.meta"
check "tail by the agent name reaches the runner" "ssh to agent@10.0.0.9" "$(cmd_tail fxa-14822 2>&1)"
check "tail by the Jira key finds the same agent" "ssh to agent@10.0.0.9" "$(cmd_tail FXA-14822 2>&1)"
check "an unknown name still says so" "ERROR: no metadata for agent 'nope'" "$(cmd_tail nope 2>&1)"
exit "$fail"
