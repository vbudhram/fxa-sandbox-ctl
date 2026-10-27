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
eval "$(sed -n '/^_PIPE_SKIP_KINDS=/p;/^_pipeline_one_line() {/,/^}/p;/^_pipeline_hash() {/,/^}/p;/^_pipeline_skip_fingerprint() {/,/^}/p;/^pipeline_skip() {/,/^}/p;/^pipeline_hold() {/,/^}/p;/^_pipeline_blocker_done() {/,/^}/p;/^pipeline_skip_changed() {/,/^}/p;/^pipeline_skip_clear() {/,/^}/p;/^_pipeline_skipped_row() {/,/^}/p;/^pipeline_skipped() {/,/^}/p' "$here/pipeline.sh")"
eval "$(sed -n '/^_snapshot_skipped() {/,/^}/p' "$here/snapshot.sh")"
declare -F _pipeline_hash >/dev/null || _pipeline_hash() { shasum | cut -c1-16; }
PIPE_STATE_DIR="$tmp"
pipeline_require() { :; }; pipeline_label_for() { echo "ai-fixme-$1"; }; _jira_sa() { return 1; }
# The ticket text, and the blocker's labels, from files the check moves.
echo "FXA-3 text" > "$tmp/ticket"; echo '[]' > "$tmp/blabels"
acli() { case "$*" in *"comment list"*) echo '{"comments":[{"body":"a person asks"}]}' ;;
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
# A skip reason is one clean line, and the key is checked before a path is built.
pipeline_skip FXA-4 "$(printf 'a\tb\nc \033[31mred\033[0m\001')$(printf 'x%.0s' $(seq 1 400))" >/dev/null
check "a skip reason is one line of at most 300 characters, with no control character" "1|300|0" \
  "$(wc -l < "$tmp/FXA-4.skipped" | tr -d ' ')|$(cut -f4 "$tmp/FXA-4.skipped" | tr -d '\n' | wc -c | tr -d ' ')|$(cut -f4 "$tmp/FXA-4.skipped" | LC_ALL=C grep -c "$(printf '[\001-\010\013-\037]')")"
pipeline_skip fxa-5 x >/dev/null
check "a lower-case key is upper-cased" "yes" "$([ -f "$tmp/FXA-5.skipped" ] && echo yes || echo no)"
check "a key that is not a ticket key fails and writes no file" "1|0" "$(pipeline_skip ../x x >/dev/null 2>&1; echo $?)|$(ls "$tmp" | grep -c '^\.\.\|^x\.skipped')"

pipeline_hold fxa-6 FXA-2 x >/dev/null
check "a hold of a lower-case key writes both files under the upper-case key" "yes|yes" "$([ -f "$tmp/FXA-6.held" ] && echo yes || echo no)|$([ -f "$tmp/FXA-6.skipped" ] && echo yes || echo no)"

# The skip kind is field 5: an exact whole word only; a hold is depends_on; old readers see the same reason.
pipeline_skip FXA-7 needs_decision pick one of two routes >/dev/null; pipeline_skip FXA-8 needs_decisions are hard >/dev/null; pipeline_hold FXA-9 FXA-2 same files >/dev/null
check "a skip kind is field 5; a near word stays in the reason; a hold is depends_on" "needs_decision|pick one of two routes||needs_decisions are hard|depends_on" \
  "$(cut -f5 "$tmp/FXA-7.skipped")|$(cut -f4 "$tmp/FXA-7.skipped")|$(cut -f5 "$tmp/FXA-8.skipped")|$(cut -f4 "$tmp/FXA-8.skipped")|$(cut -f5 "$tmp/FXA-9.skipped")"
check "a repeat skip with the same ticket text is silent and keeps its kind" "silent 2|needs_decision" "$(pipeline_skip FXA-7 needs_decision pick one of two routes)|$(cut -f5 "$tmp/FXA-7.skipped")"
check "skipped lists a 5-field record as before" "FXA-7 2" "$(pipeline_skipped FXA-7 | awk '{print $1, $2}')"

# A failed Jira read is no edit: it must not wake a model pass or replace the recorded hash.
fp7="$(cut -f1 "$tmp/FXA-7.skipped")"
real_acli="$(declare -f acli)"
acli() { case "$*" in *"comment list"*) echo '{"comments":[]}' ;; *) return 1 ;; esac; }
check "the ticket read fails: not changed" "quiet" "$(pipeline_skip_changed FXA-7 || echo quiet)"
acli() { case "$*" in *"comment list"*) return 1 ;; *) cat "$tmp/ticket" ;; esac; }
check "the comment read fails: not changed" "quiet" "$(pipeline_skip_changed FXA-7 || echo quiet)"
pipeline_skip FXA-7 needs_decision pick one of two routes >/dev/null
check "a skip whose read fails keeps the recorded hash" "$fp7" "$(cut -f1 "$tmp/FXA-7.skipped")"
eval "$real_acli"

# Under the service account, its own comments carry no 🤖: the hash skips them by author instead.
_jira_sa() { return 0; }; _jira_rest() { echo '{"displayName":"svc"}'; }
echo '[{"author":"Pat","body":"a person asks"}]' > "$tmp/comments"
acli() { case "$*" in *"comment list"*) jq -n --argjson c "$(cat "$tmp/comments")" '{comments: $c}' ;; *) cat "$tmp/ticket" ;; esac; }
fp="$(_pipeline_skip_fingerprint FXA-11)"
echo '[{"author":"Pat","body":"a person asks"},{"author":"svc","body":"Skipped: needs a label"},{"author":"Lee","body":"🤖 an old note"}]' > "$tmp/comments"
check "the service account's comment and an old 🤖 note leave the hash as it was" "$fp" "$(_pipeline_skip_fingerprint FXA-11)"
echo '[{"author":"Pat","body":"a person asks"},{"author":"Lee","body":"an answer"}]' > "$tmp/comments"
check "a person's comment changes it" "changed" "$([ "$(_pipeline_skip_fingerprint FXA-11)" != "$fp" ] && echo changed)"
_jira_rest() { return 1; }
check "a failed read of the account prints nothing" "" "$(_pipeline_skip_fingerprint FXA-11)"
_jira_sa() { return 1; }; eval "$real_acli"

exit "$fail"
