#!/usr/bin/env bash
# Offline check that a recovery finish (finish --worktree) records its PR in the run's launch
# log, so progress and the dashboard stop showing the old error.
#   bash lib/finish-recover.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
command -v jq >/dev/null || { echo "skip: needs jq"; exit 0; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
here="$(cd "$(dirname "$0")" && pwd)"
eval "$(sed -n '/^cmd_finish() {/,/^}/p' "$here/../fxa-sandbox-ctl")"
eval "$(grep '^pipeline_launch_log()' "$here/pipeline.sh")"
eval "$(sed -n '/^pipeline_progress() {/,/^}/p' "$here/pipeline.sh")"
PIPE_STATE_DIR="$tmp/state"; mkdir -p "$PIPE_STATE_DIR" "$tmp/wt"
finish_done_file_path() { echo "$1/.fxa-auto-done.json"; }
finish_push_and_pr() { echo "${PR_URL:-}"; }
finish_notify() { :; }; finish_watch_ci() { :; }; pipeline_require() { :; }
echo '{"issue":"FXA-9"}' > "$tmp/wt/.fxa-auto-done.json"
echo "ERROR: refusing to ship: personal or internal data in the PR" > "$PIPE_STATE_DIR/FXA-9.launch.log"

PR_URL=https://github.com/mozilla/fxa/pull/7 cmd_finish --worktree "$tmp/wt" --create-pr --no-ci-watch >/dev/null
check "the PR goes in the launch log, and progress shows it" "FXA-9 pr https://github.com/mozilla/fxa/pull/7" "$(pipeline_progress FXA-9 2>/dev/null)"
rm -f "$PIPE_STATE_DIR/FXA-9.launch.log"
PR_URL=https://github.com/mozilla/fxa/pull/8 cmd_finish --worktree "$tmp/wt" --create-pr --no-ci-watch >/dev/null
check "a ticket with no launch log gets none" "no" "$([ -f "$PIPE_STATE_DIR/FXA-9.launch.log" ] && echo yes || echo no)"
echo '{"issue":"../x"}' > "$tmp/wt/.fxa-auto-done.json"
PR_URL=https://github.com/mozilla/fxa/pull/9 cmd_finish --worktree "$tmp/wt" --create-pr --no-ci-watch >/dev/null
check "an issue that is not a key writes nothing" "" "$(ls "$PIPE_STATE_DIR")"
exit "$fail"
