#!/usr/bin/env bash
# Offline check for the Codex runner setup: it gets what a Claude runner gets.
#   bash lib/runtime-codex.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
here="$(cd "$(dirname "$0")" && pwd)"
eval "$(sed -n '/^_vm_git_identity() {/,/^}/p;/^_vm_session_git_rule() {/,/^}/p;/^_vm_team_context() {/,/^}/p' "$here/agent.sh")"
source "$here/runtime-codex.sh"
# Each vm_exec's command, one file per call; the VM, scp and ssh do nothing.
vm_exec() { shift; printf '%s\n' "$*" > "$tmp/exec.$(ls "$tmp" | grep -c '^exec\.')"; }
vm_name() { echo "$1"; }; vm_ip() { echo 10.0.0.1; }; _retry() { return 1; }
_vm_operator_rules() { echo "# Operator rules"; }
_vm_skill_allowlist() { :; }
lessons_approved_md() { echo "# Lessons: run the unit tests with jest"; }
memory_on() { return 0; }; memory_profile_slugs() { echo mozilla/fxa; }
memory_index_md() { echo "# Team memory for $1: settings tests need the l10n build"; }
memory_sync() { echo "synced $*" > "$tmp/synced"; }
git() { case "$*" in *user.name*) echo "Test Person" ;; *user.email*) echo test@example.com ;; esac; }
CLAUDE_HOME_DIR="$tmp/none" SANDBOX_ROOT="$tmp" LOG_DIR="$tmp"

agents() { grep -h "codex/AGENTS.md" "$tmp"/exec.* | sed -n "s/.*echo '\([A-Za-z0-9+/=]*\)' | base64 -d > \/home\/agent\/.codex\/AGENTS.md.*/\1/p" | base64 -d; }
PIPE_PROFILE=fxa FXA_SESSION_MODE=1 runtime_setup_config vm1 2>/dev/null
a="$(agents)"
check "AGENTS.md has the approved lessons and the team memory index" "1|1" \
  "$(grep -c 'Lessons: run the unit tests' <<< "$a")|$(grep -c 'Team memory for fxa' <<< "$a")"
check "the memory files are synced to the runner" "synced vm1 fxa mozilla/fxa" "$(cat "$tmp/synced" 2>/dev/null)"
check "a Slack session may use git, as a Claude one may" "1|0" "$(grep -c 'Use git as you like' <<< "$a")|$(grep -c 'You cannot commit or push' <<< "$a")"
check "the host's git identity is set for the agent" "1" "$(grep -l "user.email 'test@example.com'" "$tmp"/exec.* | wc -l | tr -d ' ')"
check "~/.claude/skills points at the Codex skills, so the guides' paths work" "1" \
  "$(grep -c 'ln -s /home/agent/.codex/skills /home/agent/.claude/skills' "$tmp"/exec.* | awk -F: '{ s += $2 } END { print s }')"

rm -f "$tmp"/exec.* "$tmp/synced"
PIPE_PROFILE=fxa runtime_setup_config vm2 2>/dev/null
check "the pipeline keeps the no-commit rule" "1" "$(agents | grep -c 'You cannot commit or push')"
exit "$fail"
