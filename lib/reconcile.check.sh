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
PIPE_QUEUE_JQL=x PIPE_STATE_DIR="$tmp"
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

# A thin green set that stays so for 3 h is done: a gate that never reports must not keep it inflight.
rm -f "$tmp/FXA-1.green-at"
check "thin green the first time: not done, the clock starts" "|1" "$(run 'ok=13 fail=0 running=0')|$(ls "$tmp" | grep -c 'FXA-1.green-at')"
echo $(( $(date +%s) - 3 * 3600 - 1 )) > "$tmp/FXA-1.green-at"
check "thin green for 3 h: done, the clock is gone" "FXA-1 done|0" "$(run 'ok=13 fail=0 running=0')|$(ls "$tmp" | grep -c 'FXA-1.green-at')"
echo $(( $(date +%s) - 4 * 3600 )) > "$tmp/FXA-1.green-at"
check "a running check stops the clock" "|0" "$(run 'ok=13 fail=0 running=2')|$(ls "$tmp" | grep -c 'FXA-1.green-at')"
# A PR read that gives "none - -" (no PR, or gh failed) must not stop the keys after it.
( jira_inflight_keys() { printf '%s\n' FXA-1 FXA-2; }
  gh_pr_state() { case "$1" in FXA-1) echo "FXA-1 none - -" ;; *) echo "FXA-2 12 MERGED ok=20 fail=0 running=0" ;; esac; }
  : >"$tmp/labels"; out="$(cmd_reconcile 2>&1)"
  check "a 'none - -' read: that key says so, and the next key still merges" "yes|FXA-2 merged" \
    "$(grep -q 'FXA-1 pr none - (could not read the PR)' <<< "$out" && echo yes)|$(cat "$tmp/labels")"
  exit "$fail" ) || fail=1
exit "$fail"
