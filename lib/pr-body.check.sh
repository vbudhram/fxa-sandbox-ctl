#!/usr/bin/env bash
# Offline check of session_pr_body: the agent's new PR body goes to GitHub with no push,
# after the PII guard, with the Claude footer dropped, and is read back.
#   bash lib/pr-body.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "skip: needs jq and python3"; exit 0; }
here="$(cd "$(dirname "$0")" && pwd)"; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
FINISH_LIB_DIR="$here"
eval "$(sed -n '/^session_pr_body() {/,/^}/p;/^_session_pr_parts() {/,/^}/p' "$here/session.sh")"
eval "$(sed -n '/^_finish_pii_guard() {/,/^}/p;/^_finish_soft_keys() {/,/^}/p' "$here/finish.sh")"
eval "$(sed -n '/^gh_pr_body_set() {/,/^}/p;/^_pr_body_clean() {/,/^}/p' "$here/github.sh")"
PR=https://github.com/mozilla/fxa/pull/7
session_get() { case "$2" in pr_url) echo "$PR" ;; jira) echo FXA-1 ;; esac; }
worktree_branch_for() { echo "agent-$1"; }
_session_history_add() { echo "$3" >> "$tmp/history"; }
# The runner's file, and a fake GitHub that keeps the body in a file. TAKE=0: a PATCH that GitHub drops.
vm_exec_as_agent() { cat "$tmp/new" 2>/dev/null; }
TAKE=1
gh() {
  [ "$1" = api ] || return 9
  if [ "${3:-}" = PATCH ]; then echo patch >> "$tmp/calls"; [ "$TAKE" = 1 ] && cat > "$tmp/body" || cat >/dev/null; return 0; fi
  [ "$2" = repos/mozilla/fxa/pulls/7 ] || return 9
  cat "$tmp/body"
}
run() { : > "$tmp/calls"; session_pr_body k1 2>&1; echo "rc=$?"; }

printf 'Because:\n\nCloses: #\n' > "$tmp/body"
printf 'Because:\n\nCloses: FXA-15064\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)\n' > "$tmp/new"
check "the new body goes to the PR, without the footer, and is recorded" \
  "Updated the PR description: $PR|rc=0|Because:@@Closes: FXA-15064|patch|Updated the description of $PR" \
  "$(run | paste -sd'|' -)|$(paste -sd'@' "$tmp/body" | sed 's/@@*/@@/')|$(cat "$tmp/calls")|$(cat "$tmp/history")"
check "the same body again: no write" "The PR description already says that.|rc=0|" "$(run | paste -sd'|' -)|$(cat "$tmp/calls")"
printf 'Ping me at jane.doe@gmail.com\n' > "$tmp/new"
check "personal data is refused before any write" "1|rc=1|" "$(run | grep -c 'refusing to ship')|$(run | tail -1)|$(cat "$tmp/calls")"
rm -f "$tmp/new"
check "no file: refused" "the new PR body is missing or empty|rc=1" "$(run | paste -sd'|' -)"
printf 'New text\n' > "$tmp/new"; TAKE=0
check "a write GitHub did not take is an error" "GitHub did not take the new PR description for $PR|rc=1" "$(run | paste -sd'|' -)"
PR=""; check "a session with no PR is refused" "no PR for k1|rc=1" "$(run | paste -sd'|' -)"
exit "$fail"
