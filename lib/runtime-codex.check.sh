#!/usr/bin/env bash
# Offline check for the Codex runner setup: it gets what a Claude runner gets.
#   bash lib/runtime-codex.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
here="$(cd "$(dirname "$0")" && pwd)"
eval "$(sed -n '/^_vm_git_identity() {/,/^}/p;/^_vm_session_git_rule() {/,/^}/p;/^_vm_team_context() {/,/^}/p;/^_vm_team_rules() {/,/^}/p;/^_vm_repo_dirs() {/,/^}/p' "$here/agent.sh"; sed -n '/^profile_file() {/,/^}/p' "$here/config.sh")"
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
CLAUDE_HOME_DIR="$tmp/none" SANDBOX_ROOT="$(cd "$here/.." && pwd)" LOG_DIR="$tmp"

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
# Notes and skills follow the repo: every profile with an fxa row gets FxA's, and only those.
rm -f "$tmp"/exec.*; PIPE_PROFILE=fxa runtime_setup_config vm3 2>/dev/null; a="$(agents)"
check "an fxa row gets FxA's repo notes, after the sandbox section" "1|1|yes" \
  "$(grep -c '^# Repo notes: mozilla/fxa' <<< "$a")|$(grep -c 'fxa-start' <<< "$a")|$( [ "$(grep -n '^# Sandbox VM' <<< "$a" | cut -d: -f1)" -lt "$(grep -n '^# Repo notes' <<< "$a" | cut -d: -f1)" ] && echo yes)"
memory_profile_slugs() { echo mozilla/blurts-server; }
rm -f "$tmp"/exec.*; PIPE_PROFILE=other runtime_setup_config vm4 2>/dev/null; a="$(agents)"
check "a profile with no fxa row gets no FxA-only line" "0|0|0" \
  "$(grep -c 'Repo notes\|Team rules' <<< "$a")|$(grep -c 'fxa-start\|fxa-verify\|ai/AGENTS.md' <<< "$a")|$(grep -ci 'FxA sandbox' <<< "$a")"
eval "$(sed -n '/^_vm_skill_allowlist() {/,/^}/p' "$here/agent.sh")"
check "the FxA skills ship only with an fxa row; the shared ones always" "0|1" \
  "$(_vm_skill_allowlist | grep -c '^fxa-verify$')|$(_vm_skill_allowlist | grep -c '^fxa-vm-handoff$')"
memory_profile_slugs() { printf '%s\n' mozilla/PyFxA mozilla/fxa; }
check "a two-repo team with fxa gets FxA's skills" "1|1" "$(_vm_skill_allowlist | grep -c '^fxa-verify$')|$(_vm_skill_allowlist | grep -c '^fxa-stack$')"
# A team's own rules come after the repo notes, which they override.
mkdir -p "$tmp/root/profiles/t" "$tmp/root/repos/mozilla__fxa"; echo "Run fxa-start." > "$tmp/root/repos/mozilla__fxa/notes.md"; echo "Never run fxa-start." > "$tmp/root/profiles/t/CLAUDE.md"
check "team rules follow the repo notes" "Repo notes: mozilla/fxa|Team rules: t" \
  "$(SANDBOX_ROOT="$tmp/root" PIPE_PROFILE=t _vm_team_rules | grep -o 'Repo notes: mozilla/fxa\|Team rules: t' | paste -sd'|' -)"
# The memory hooks: a Bash result and a patch run fxa-mem hook, and the launch trusts them.
toml() { grep -h "codex/config.toml" "$tmp"/exec.* | sed -n "s/.*echo '\([A-Za-z0-9+/=]*\)' | base64 -d > \/home\/agent\/.codex\/config.toml.*/\1/p" | base64 -d; }
rm -f "$tmp"/exec.*; PIPE_PROFILE=fxa runtime_setup_config vm5 2>/dev/null; toml > "$tmp/config.toml"
hk='command -v fxa-mem >/dev/null && fxa-mem hook; exit 0'
check "config.toml has the memory hooks" "^Bash$|^(apply_patch|Edit|Write|Bash)$|command|$hk|5" "$(python3 -c '
import tomllib, sys
h = tomllib.load(open(sys.argv[1], "rb"))["hooks"]; c = h["PostToolUse"][0]["hooks"][0]
print("|".join([h["PostToolUse"][0]["matcher"], h["PreToolUse"][0]["matcher"], c["type"], c["command"], str(c["timeout"])]))' "$tmp/config.toml" 2>&1)"
check "both launch lines trust the hooks" "1|1" "$(runtime_launch_cmd | grep -c -- '--dangerously-bypass-hook-trust')|$(FXA_SESSION_MODE=1 runtime_launch_cmd | grep -c -- '--dangerously-bypass-hook-trust')"
exit "$fail"
