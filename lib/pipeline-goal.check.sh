#!/usr/bin/env bash
# pipeline-goal.check.sh: the pipeline's goal fits Claude's cap at the longest summary,
# and names the Sonnet review and PR subagents for Claude only.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; root="$(dirname "$here")"
fail=0; ok() { echo "ok   $1"; }; bad() { echo "FAIL $1: $2"; fail=1; }
render() { # render <runtime> <functional tests true|false>
  ( cd "$root"; export FXA_AGENT_RUNTIME="$1"
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
exit "$fail"
