#!/usr/bin/env bash
# Offline check of the squash commit's body: the agent's short body, else only the closing line.
#   bash lib/finish-commit.check.sh
set -euo pipefail
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
eval "$(sed -n '/^_finish_commit_body() {/,/^}/p' "$(dirname "$0")/finish.sh")"
short=$'Because:\n\n* login.complete fired only with flow events\n\nThis commit:\n\n* Emit it from the flow-complete signal\n\nCloses FXA-14303\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)'
pr=$'## Because\n\n- a long reason\n\n## This pull request\n\n- 12 bullets\n\n## Issue that this pull request solves\n\nCloses: FXA-14303\n\n## Checklist\n\n- [x] tests'
check "the agent's short body, without the footer" \
  $'Because:\n\n* login.complete fired only with flow events\n\nThis commit:\n\n* Emit it from the flow-complete signal\n\nCloses FXA-14303' \
  "$(_finish_commit_body "$short" "$pr")"
check "no short body: only the PR body's closing line" "Closes: FXA-14303" "$(_finish_commit_body "" "$pr")"
check "no short body and no ticket: nothing" "" "$(_finish_commit_body "" $'## Because\n\n- why\n\nCloses:')"
check "a long short body is cut to 30 lines" "30" "$(_finish_commit_body "$(seq -f '* line %.0f' 1 50)" "$pr" | wc -l | tr -d ' ')"
exit "$fail"
