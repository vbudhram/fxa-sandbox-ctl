#!/usr/bin/env bash
# Offline check for holds: a ticket that waits for another to merge stays quiet in precheck
# until its blocker merges, and the dashboard shows what it waits on.
#   bash lib/pipeline-hold.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
command -v jq >/dev/null || { echo "skip: needs jq"; exit 0; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
here="$(cd "$(dirname "$0")" && pwd)"
eval "$(sed -n '/^_pipeline_hash() {/,/^}/p;/^_pipeline_skip_fingerprint() {/,/^}/p;/^pipeline_skip() {/,/^}/p;/^pipeline_hold() {/,/^}/p;/^_pipeline_blocker_done() {/,/^}/p;/^pipeline_skip_changed() {/,/^}/p;/^pipeline_skip_clear() {/,/^}/p;/^_pipeline_skipped_row() {/,/^}/p;/^pipeline_skipped() {/,/^}/p' "$here/pipeline.sh")"
eval "$(sed -n '/^_snapshot_skipped() {/,/^}/p' "$here/snapshot.sh")"
declare -F _pipeline_hash >/dev/null || _pipeline_hash() { shasum | cut -c1-16; }
PIPE_STATE_DIR="$tmp"
pipeline_require() { :; }; pipeline_label_for() { echo "ai-fixme-$1"; }
# The ticket text, and the blocker's labels, from files the check moves.
echo "FXA-3 text" > "$tmp/ticket"; echo '[]' > "$tmp/blabels"
acli() { case "$*" in *"comment list"*) echo '{"comments":[]}' ;;
  *"--fields labels,status"*) jq -n --argjson l "$(cat "$tmp/blabels")" '{fields: {labels: $l, status: {statusCategory: {key: "indeterminate"}}}}' ;;
  *) cat "$tmp/ticket" ;; esac; }

check "hold records a skip: comment the first time" "comment" "$(pipeline_hold FXA-3 FXA-2 edits the same routes)"
check "held, blocker not merged: quiet" "quiet" "$(pipeline_skip_changed FXA-3 || echo quiet)"
check "the snapshot names what it waits on" "FXA-2|true" "$(_snapshot_skipped | jq -r '.[0] | "\(.held_by)|\(.reason | startswith("held until FXA-2 merges"))"')"
echo '["ai-fixme-merged"]' > "$tmp/blabels"
check "the blocker merged: one pass looks again" "unblocked: FXA-2 is merged" "$(pipeline_skip_changed FXA-3)"
echo '[]' > "$tmp/blabels"; echo "FXA-3 text, with an answer" > "$tmp/ticket"
check "the held ticket itself changed: it wakes too" "changed" "$(pipeline_skip_changed FXA-3)"
pipeline_skip FXA-3 a plain skip now >/dev/null
check "a plain skip replaces the hold" "no|null" "$([ -f "$tmp/FXA-3.held" ] && echo yes || echo no)|$(_snapshot_skipped | jq -r '.[0].held_by')"
pipeline_hold FXA-3 FXA-2 again >/dev/null; pipeline_skip_clear FXA-3
check "a launch clears the hold with the skip" "no|no" "$([ -f "$tmp/FXA-3.held" ] && echo yes || echo no)|$([ -f "$tmp/FXA-3.skipped" ] && echo yes || echo no)"
check "a hold needs a blocker key, not itself" "1|1" "$(pipeline_hold FXA-3 >/dev/null 2>&1; echo $?)|$(pipeline_hold FXA-3 FXA-3 >/dev/null 2>&1; echo $?)"
exit "$fail"
