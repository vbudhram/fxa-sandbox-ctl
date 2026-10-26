#!/usr/bin/env bash
# Offline check that a failed state push warns and does not fail pipeline_unlock: under set -e that status
# ended precheck before its pass row and its quiet line, and the pass then woke a paid model.
#   bash lib/state-push.check.sh
set -u
here="$(cd "$(dirname "$0")" && pwd)"; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^pipeline_unlock() {/,/^}/p;/^pipeline_state_push() {/,/^}/p' "$here/pipeline.sh")"
_pipeline_state_exclude='x'; pipeline_require() { :; }
gcloud() { return 1; }
out="$(set -euo pipefail; PIPE_LOCK_DIR="$tmp/l" PIPE_STATE_DIR="$tmp" PIPE_STATE_URI=gs://example/state; mkdir -p "$PIPE_LOCK_DIR"; pipeline_unlock >/dev/null 2>&1; echo "after unlock")"
if [ "$out" = "after unlock" ]; then echo "ok   a failed state push does not end the caller under set -e"; else echo "FAIL a failed state push does not end the caller under set -e: want [after unlock] got [$out]"; exit 1; fi
