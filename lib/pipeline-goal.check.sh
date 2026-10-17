#!/usr/bin/env bash
# pipeline-goal.check.sh: the pipeline's goal fits Claude's cap at the longest summary,
# and names the Sonnet review and PR subagents for Claude only.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; root="$(dirname "$here")"
fail=0; ok() { echo "ok   $1"; }; bad() { echo "FAIL $1: $2"; fail=1; }
render() { # render <runtime> <functional tests true|false> [profile]
  ( cd "$root"; export FXA_AGENT_RUNTIME="$1" PIPE_PROFILE="${3:-fxa}" SANDBOX_ROOT="$root"
    source lib/config.sh >/dev/null 2>&1; source lib/agent.sh >/dev/null 2>&1; source "lib/runtime-$1.sh" >/dev/null 2>&1
    eval "$(sed -n '/^_jira_render_prompt() {/,/^}/p' fxa-sandbox-ctl)"
    _jira_render_prompt FXA-99999 fxa-99999 "$(printf 'x%.0s' $(seq 1 90))" ctx "$2" )
}
for ft in false true; do
  p="$(render claude $ft)"
  [ "${#p}" -le 4000 ] && ok "claude goal fits the cap (functional=$ft, ${#p} chars)" || bad "claude goal over the cap" "${#p} chars"
  grep -q 'fxa-reviewer subagent' <<< "$p" && grep -q 'fxa-writer subagent' <<< "$p" && ok "claude goal names both subagents" || bad "subagents" "not named"
done
p="$(render codex false)"
grep -q 'fxa-reviewer' <<< "$p" && bad "codex goal" "names a Claude subagent" || ok "codex goal keeps the general wording"
# Another team's own steps (its goal.md, here a record's copy) take the place of FxA's 1-8; the shared tail stays.
# The fixture is the largest goal a record may hold (team_record.py), so the cap holds for every record.
export FXA_TEAMS_DIR; FXA_TEAMS_DIR="$(mktemp -d)"; trap 'rm -rf "$FXA_TEAMS_DIR"' EXIT; mkdir -p "$FXA_TEAMS_DIR/gt"
{ printf '1. Run sync-verify/verify.sh --run, DO NOT push.\n'; head -c 2510 /dev/zero | tr '\0' 'x'; } > "$FXA_TEAMS_DIR/gt/goal.md"
p="$(render claude true gt)"
[ "$(wc -c < "$FXA_TEAMS_DIR/gt/goal.md")" -le 2560 ] && [ "${#p}" -le 4000 ] && ok "the largest record goal fits the cap (${#p} chars)" || bad "a record goal over the cap" "${#p} chars"
grep -q 'sync-verify/verify.sh --run' <<< "$p" && grep -q '^9\. Write /workspace/.fxa-auto-done.json' <<< "$p" && grep -q 'DO NOT push' <<< "$p" \
  && ok "a team's goal has its own steps, then the shared handoff and tail" || bad "team goal" "missing its steps or the shared tail"
grep -qE 'fxa-verify|fxa-reviewer|eslint|\.github/PULL_REQUEST_TEMPLATE|Closes FXA' <<< "$p" && bad "team goal" "names FxA's steps" || ok "a team's goal names none of FxA's steps"
grep -q 'fxa-verify' <<< "$(render claude false)" && ok "FxA keeps its own steps" || bad "fxa goal" "lost its steps"
exit "$fail"
