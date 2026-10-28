#!/usr/bin/env bash
# Offline check for finish_add_labels: a team's extra PR labels go on after the create, one at a time.
#   bash lib/finish-labels.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^finish_add_labels() {/,/^}/p' "$(dirname "$0")/finish.sh")"
# The fake GitHub API: records each label call; the repo has no "missing" label.
gh() { local IFS=' '; echo "$*" >> "$tmp/calls"; case "$*" in *missing*) return 1 ;; esac; }
url=https://github.com/mozilla/fxa/pull/7
out="$(PIPE_PR_LABELS="coderabbit,auto,missing" finish_add_labels "$url" 2>&1)"; rc=$?
check "each extra label is added to the PR's issue, auto is skipped (create adds it)" "api -X POST repos/mozilla/fxa/issues/7/labels -f labels[]=coderabbit|api -X POST repos/mozilla/fxa/issues/7/labels -f labels[]=missing" "$(paste -sd'|' "$tmp/calls")"
check "a label the repo lacks warns and does not fail" "0|1" "$rc|$(grep -c 'could not add the missing label' <<< "$out")"
rm -f "$tmp/calls"; PIPE_PR_LABELS="" finish_add_labels "$url" 2>/dev/null
check "no extra labels: no call" "no" "$([ -e "$tmp/calls" ] && echo yes || echo no)"
exit "$fail"
