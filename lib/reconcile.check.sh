#!/usr/bin/env bash
# Offline check that reconcile labels a PR done only after its full check set settles.
#   bash lib/reconcile.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^cmd_reconcile() {/,/^}/p' "$(dirname "$0")/../fxa-sandbox-ctl")"
PIPE_QUEUE_JQL=x
jira_inflight_keys() { echo FXA-1; }
pipeline_progress() { echo "$1 pr 1"; }
gh_pr_state() { echo "$1 1 OPEN $(cat "$tmp/rollup")"; }
gh_gate_stuck() { return 1; }
gh_red_infra() { echo "extract(Bad credentials)"; }
cmd_label() { echo "$1 $2" >>"$tmp/labels"; }
_jira_keys_for_jql() { :; }
pipeline_skip_prune() { cat >/dev/null; }

run() { : >"$tmp/labels"; echo "$1" >"$tmp/rollup"; cmd_reconcile >/dev/null 2>&1; cat "$tmp/labels"; }
check "thin green set is not done" "" "$(run 'ok=9 fail=0 running=0')"
check "full green set is done" "FXA-1 done" "$(run 'ok=19 fail=0 running=0')"
check "thin infra-red set is not done" "" "$(run 'ok=8 fail=1 running=0')"
check "full infra-red set is done" "FXA-1 done" "$(run 'ok=18 fail=1 running=0')"

exit "$fail"
