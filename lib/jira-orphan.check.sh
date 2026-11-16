#!/usr/bin/env bash
# Offline check that jira_orphan_keys asks only for the tickets this pipeline launched in 30 days,
# with none of its labels and not done.
#   bash lib/jira-orphan.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^jira_orphan_keys() {/,/^}/p' "$(dirname "$0")/jira.sh")"
eval "$(sed -n '/^pipeline_states() /p' "$(dirname "$0")/pipeline.sh")"
pipeline_require() { :; }; pipeline_jira_scope() { echo 'project = FXA'; }
pipeline_label_for() { case "$1" in public|queued) echo ai-fixme ;; *) echo "ai-fixme-$1" ;; esac; }
_jira_keys_for_jql() { printf '%s\n' "$1"; }
PIPE_STATE_DIR="$tmp"
check "no launch record: no Jira read" "" "$(jira_orphan_keys)"
touch "$tmp/FXA-2.launch.tsv" "$tmp/FXA-1.launch.tsv" "$tmp/FXA-1.launch.log" "$tmp/notakey.launch.tsv"
touch -t 202001010000 "$tmp/FXA-3.launch.tsv"
q="$(jira_orphan_keys)"
check "only the keys launched in 30 days, in one read" "1" "$(grep -c 'key in (FXA-1,FXA-2) AND' <<< "$q")"
check "a ticket with none of the pipeline's labels, and not done" "1" \
  "$(grep -c '(labels is EMPTY OR labels not in ("ai-fixme", "ai-fixme-inflight", "ai-fixme-done", "ai-fixme-blocked", "ai-fixme-merged", "ai-fixme-rejected", "ai-fixme-diff", "ai-fixme")) AND statusCategory != Done$' <<< "$q")"
exit "$fail"
