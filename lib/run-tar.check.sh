#!/usr/bin/env bash
# Offline check that the gce run tar, which holds the run's credentials, never stays in LOG_DIR.
#   bash lib/run-tar.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
here="$(cd "$(dirname "$0")" && pwd)"
eval "$(sed -n '/^_put_run_files() {/,/^}/p' "$here/agent.sh")"
worktree_secret_files() { :; }
LOG_DIR="$tmp/logs"; mkdir -p "$LOG_DIR" "$tmp/slot"; echo 'export ANTHROPIC_API_KEY=sk-ant-test-x' > "$tmp/slot/.fxa-auto-token"
# tar dies part way: it has written some of the archive.
tar() { while [ "$1" != -czf ]; do shift; done; echo partial > "$2"; return 1; }
vm_put() { echo put >> "$tmp/puts"; }; vm_exec() { :; }
_put_run_files agent-x1 "$tmp/slot" >/dev/null 2>&1; rc=$?
check "a tar that fails part way leaves no archive and ships nothing" "1|no|no" "$rc|$([ -e "$LOG_DIR/agent-x1-run.tar" ] && echo yes || echo no)|$([ -e "$tmp/puts" ] && echo yes || echo no)"
check "agent_stop removes a run tar a killed launch left" "yes" \
  "$(sed -n '/^agent_stop() {/,/^}/p' "$here/agent.sh" | grep -q 'rm -f .*"${LOG_DIR}/${name}-run.tar"' && echo yes)"
# The host's Figma export ships into the runner with the run files.
mkdir -p "$tmp/slot/.fxa-auto-design"; echo svg > "$tmp/slot/.fxa-auto-design/phone.svg"
tar() { while [ "$1" != -czf ]; do shift; done; shift; shift; printf '%s\n' "$@" > "$tmp/tarred"; : > "$LOG_DIR/agent-x2-run.tar"; }
_put_run_files agent-x2 "$tmp/slot" >/dev/null 2>&1
check "the design folder from Figma ships with the run files" "1" "$(grep -cx './.fxa-auto-design' "$tmp/tarred")"
[ "$fail" = 0 ] && echo "all checks pass"
exit "$fail"
