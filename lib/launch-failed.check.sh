#!/usr/bin/env bash
# Offline check that a failed launch returns a ticket to the queue only when it has no open PR.
#   bash lib/launch-failed.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^_jira_launch_failed() {/,/^}/p' "$(dirname "$0")/../fxa-sandbox-ctl")"
PIPE_NAME=fxa-ai-fixme LOG_DIR="$tmp"
jira_inflight_keys() { printf 'FXA-1\nFXA-2\n'; }
cmd_label() { echo "$1 $2" >>"$tmp/labels"; }
gh_pr_state() {
  case "$1" in
    FXA-1) echo "FXA-1 21304 OPEN ok=7 fail=1 running=0" ;;
    FXA-2) echo "FXA-2 none - -" ;;
  esac
}

touch "$tmp/fxa-1.meta" "$tmp/fxa-2.meta"
out="$(_jira_launch_failed FXA-1 fxa-1 2>&1)"
check "open PR keeps its label" "" "$(cat "$tmp/labels" 2>/dev/null)"
check "open PR says why" "yes" "$(grep -q 'PR #21304 is open' <<<"$out" && echo yes)"
check "meta removed" "gone" "$([ -e "$tmp/fxa-1.meta" ] && echo present || echo gone)"

_jira_launch_failed FXA-2 fxa-2 2>/dev/null
check "no PR returns to the queue" "FXA-2 public" "$(cat "$tmp/labels" 2>/dev/null)"

exit "$fail"
