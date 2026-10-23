#!/usr/bin/env bash
# claude-tools.check.sh: a runner's claude gets only the built-in tools runs call, the same on the first
# turn and each resume (else the cached prefix changes), and an ask gets no skill listing.
#   Checks lib/mcp-token.sh _CLAUDE_TOOLS_FLAG, lib/runtime-claude.sh, lib/session.sh and lib/answer.sh.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
fail=0; check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; fail=1; fi; }
eval "$(grep '^_CLAUDE_TOOLS_FLAG=' "$root/lib/mcp-token.sh")"
check "the tool list keeps what runs call and drops what none called" "keep|drop" \
  "$(for t in Bash Read Edit Write Agent Skill SendMessage ToolSearch; do [[ ",${_CLAUDE_TOOLS_FLAG#* --tools }," == *",$t,"* ]] || echo miss; done | grep -q . && echo miss || echo keep)|$(for t in Workflow CronCreate ScheduleWakeup EnterWorktree NotebookEdit WebSearch; do [[ ",${_CLAUDE_TOOLS_FLAG#* --tools }," == *",$t,"* ]] && echo has; done | grep -q . && echo has || echo drop)"
check "the first turn and each resume pass the same tool list" "1|1" \
  "$(grep -c 'bypassPermissions${_CLAUDE_TOOLS_FLAG}' "$root/lib/runtime-claude.sh")|$(grep -c 'bypassPermissions${_CLAUDE_TOOLS_FLAG}' "$root/lib/session.sh")"
check "an ask gets Read, Bash and ToolSearch only, and no skill listing" "1|1" \
  "$(grep -c -- '--tools Read,Bash,ToolSearch' "$root/lib/answer.sh")|$(grep -c -- '--disable-slash-commands' "$root/lib/answer.sh")"
check "with no skill listing, an ask is told where the jira-link skill is" "1" "$(grep -c 'Read /home/agent/.claude/skills/fxa-jira-link/SKILL.md first' "$root/lib/answer.sh")"
exit "$fail"
