#!/usr/bin/env bash
# Offline check for lib/targets.sh: an old record reads as one target, a switch keeps both, a resume carries the
# open ones.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
source "$here/config.sh"
export FXA_SESSION_STORE_URI="" FXA_SESSION_BACKUP_URI=""
FXA_SESSION_DIR="$tmp" source "$here/session.sh"
_session_db_sync() { :; }
export PIPE_REPO_SLUG=mozilla/syncstorage-rs
source "$here/targets.sh"
pr2750=https://github.com/mozilla/syncstorage-rs/pull/2750 pr2738=https://github.com/mozilla/syncstorage-rs/pull/2738
echo '{"state":"active","branch":"agent-46e5fc","pr_url":"'"$pr2750"'"}' > "$tmp/agent-46e5fc.json"

check "an old record reads as one target" "1|agent-46e5fc|$pr2750|/workspace|0" \
  "$(targets_json agent-46e5fc | jq -r 'length, (.[0] | .branch, .pr_url, .target_path)' | paste -sd'|' -)|$(targets_current agent-46e5fc)"
check "the read rewrites nothing" "null" "$(jq -c .targets "$tmp/agent-46e5fc.json")"

t2738="$(jq -nc --arg u "$pr2738" '{repo: "mozilla/syncstorage-rs", branch: "stor-55", pr_url: $u, review_pr: $u, target_path: "/home/agent/targets/stor-55", target_base: "master", source: "checkout"}')"
check "a switch to PR 2738 adds it as target 1" 1 "$(target_switch agent-46e5fc "$t2738")"
check "the top level is now PR 2738's branch and PR" "stor-55|$pr2738|$pr2738|/home/agent/targets/stor-55" \
  "$(session_get agent-46e5fc branch)|$(session_get agent-46e5fc pr_url)|$(session_get agent-46e5fc review_pr)|$(session_get agent-46e5fc target_path)"
check "the first target keeps its branch and PR" "agent-46e5fc|$pr2750|/workspace" \
  "$(targets_json agent-46e5fc | jq -r '.[0] | .branch, .pr_url, .target_path' | paste -sd'|' -)"
session_set agent-46e5fc push_lease abc123
t0="$(jq -nc --arg u "$pr2750" '{repo: "mozilla/syncstorage-rs", branch: "agent-46e5fc"}')"
check "a switch back finds target 0, and target 1 keeps its push lease" "0|agent-46e5fc|$pr2750||abc123" \
  "$(target_switch agent-46e5fc "$t0")|$(session_get agent-46e5fc branch)|$(session_get agent-46e5fc pr_url)|$(session_get agent-46e5fc push_lease)|$(targets_json agent-46e5fc | jq -r '.[1].push_lease')"
check "a close of PR 2750 ends its target and leaves one open" "1|closed" \
  "$(target_end agent-46e5fc "$pr2750" CLOSED)|$(targets_json agent-46e5fc | jq -r '.[0].state')"

# A resume carries the open targets and drops the merged or closed ones.
gh() { case "$*" in *2738*) echo OPEN ;; *2750*) echo "${STATE_2750:-OPEN}" ;; esac; }
echo '{"state":"stopped","branch":"agent-46e5fc","pr_url":"'"$pr2750"'"}' > "$tmp/agent-old.json"
target_switch agent-old "$t2738" >/dev/null
echo '{"state":"starting"}' > "$tmp/agent-new.json"; session_set agent-new branch stor-55 pr_url "$pr2738"
targets_carry agent-new agent-old
check "a resume carries both open targets, PR 2738 stays current, and the new runner has only /workspace" "2|agent-46e5fc|stor-55|1||/workspace" \
  "$(targets_json agent-new | jq -r 'length, .[0].branch, .[1].branch' | paste -sd'|' -)|$(targets_current agent-new)|$(targets_json agent-new | jq -r '.[0].target_path')|$(targets_json agent-new | jq -r '.[1].target_path')"
echo '{"state":"starting"}' > "$tmp/agent-new2.json"; session_set agent-new2 branch stor-55 pr_url "$pr2738"
STATE_2750=CLOSED targets_carry agent-new2 agent-old
check "a resume drops the closed PR 2750: one target, no list" "null" "$(jq -c .targets "$tmp/agent-new2.json")"
echo '{"state":"starting"}' > "$tmp/agent-one.json"
targets_carry agent-one agent-new2
check "a resume of a one-target session writes no targets" "null" "$(jq -c .targets "$tmp/agent-one.json")"

exit "$fail"
