#!/usr/bin/env bash
# agent-blocked.check.sh: a run that cannot pass a step writes .fxa-auto-blocked.txt and stops,
# and progress reports it as agent-blocked with its first line, not as a run to relaunch.
#   Checks lib/pipeline.sh _pipeline_stalled_reason and the goal in fxa-sandbox-ctl.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; root="$(dirname "$here")"
fail=0; check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
render() { ( cd "$root"; export FXA_AGENT_RUNTIME=claude PIPE_PROFILE="$1" SANDBOX_ROOT="$root" FXA_TEAMS_DIR="$tmp/teams"
  source lib/config.sh >/dev/null 2>&1; source lib/agent.sh >/dev/null 2>&1; source lib/runtime-claude.sh >/dev/null 2>&1
  eval "$(sed -n '/^_jira_render_prompt() {/,/^}/p' fxa-sandbox-ctl)"; _jira_render_prompt FXA-1 fxa-1 title ctx false ); }
mkdir -p "$tmp/teams/gt" && echo '1. Run the tests.' > "$tmp/teams/gt/goal.md"
check "the FxA goal and a team's goal say how to stop when blocked" "1|1" \
  "$(render fxa | grep -c '/workspace/.fxa-auto-blocked.txt')|$(render gt | grep -c '/workspace/.fxa-auto-blocked.txt')"

eval "$(sed -n '/^_pipeline_stalled_reason() {/,/^}/p' "$root/lib/pipeline.sh")"
# Not named wt: the function's own local wt would hide it from the stub.
W="$tmp/wt"; mkdir -p "$W"
worktree_branch_for() { echo agent-x; }; _telemetry_worktree_for_key() { echo "$W"; }
vm_is_running() { return 0; }; agent_alive() { return 1; }
check "a run that ended with no handoff and no note is exited-without-handoff" "exited-without-handoff" "$(_pipeline_stalled_reason FXA-1 60)"
printf 'step 2: `spec` still fails; "tried" $(x)\nmore\n' > "$W/.fxa-auto-blocked.txt"
check "a run that wrote the blocked note is agent-blocked, with its first line in plain characters" \
  "agent-blocked: step 2: spec still fails tried x" "$(_pipeline_stalled_reason FXA-1 60)"
echo '{}' > "$W/.fxa-auto-done.json"
check "a handoff wins over the note" "none" "$(_pipeline_stalled_reason FXA-1 60 || echo none)"
exit "$fail"
