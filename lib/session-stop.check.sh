#!/usr/bin/env bash
# Offline check for session_stop: a runner delete that fails is an error, and marks the session for a retry.
#   bash lib/session-stop.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
here="$(cd "$(dirname "$0")" && pwd)"
eval "$(sed -n '/^session_stop() {/,/^}/p' "$here/session.sh")"
worktree_branch_for() { echo "agent-$1"; }
_session_usage_close() { :; }; _session_save() { :; }; _session_desktop_close() { :; }
session_set() { shift; printf '%s ' "$@" >> "$tmp/set"; }
agent_stop() { return 1; }
check "a failed delete: the stop fails, and the session is marked for a retry" "1|state stopped runner_left 1" \
  "$(session_stop a1 >/dev/null 2>&1; echo $?)|$(sed 's/ $//' "$tmp/set")"
: > "$tmp/set"; agent_stop() { return 0; }
check "a delete that works: the stop succeeds, with no retry mark" "0|state stopped" "$(session_stop a1 >/dev/null 2>&1; echo $?)|$(sed 's/ $//' "$tmp/set")"
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
