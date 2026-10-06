#!/usr/bin/env bash
# Offline check for needs-you: new once, then seen with the date; a label change resets it.
#   bash lib/needs-you.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
here="$(dirname "$0")"
eval "$(sed -n '/^cmd_needs_you() {/,/^}/p;/^cmd_label() {/,/^}/p' "$here/../fxa-sandbox-ctl")"
eval "$(sed -n '/^jira_normalize_key() {/,/^}/p' "$here/jira.sh")"
_key() { jira_normalize_key "$1"; }
PIPE_STATE_DIR="$tmp" PIPE_LABEL_PREFIX=ai-fixme
jira_label_set() { :; }; _reap_key() { :; }
check "the first report is new" "new" "$(cmd_needs_you fxa-1)"
check "later passes see it, with the date" "seen $(date -u +%F)" "$(cmd_needs_you FXA-1)"
cmd_label FXA-1 blocked >/dev/null 2>&1
check "a label change makes the next item new" "new" "$(cmd_needs_you FXA-1)"
exit "$fail"
