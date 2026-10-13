#!/usr/bin/env bash
# Offline check for finish_diff_only: a read-only profile's run becomes a patch and one comment.
#   bash lib/finish-diff.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^finish_diff_only() {/,/^}/p;/^finish_done_file_path() {/,/^}/p;/^_finish_pii_guard() {/,/^}/p' "$here/finish.sh")"
FINISH_LIB_DIR="$here"
FXA_DONE_FILENAME=.fxa-auto-done.json PIPE_STATE_DIR="$tmp/state" PIPE_PROFILE=monitor FXA_WORKTREE_BASE=main
jira_comment() { printf '%s|%s\n' "$1" "$2" > "$tmp/comment"; }
g() { git -c init.defaultBranch=main -c user.name=t -c user.email=t@example.com "$@"; }

g init -q --bare "$tmp/origin.git"; g clone -q "$tmp/origin.git" "$tmp/wt" 2>/dev/null
printf 'a\n' > "$tmp/wt/a.txt"; g -C "$tmp/wt" add a.txt; g -C "$tmp/wt" commit -qm init; g -C "$tmp/wt" push -q origin main
printf 'a\nb\n' > "$tmp/wt/a.txt"; printf 'new\n' > "$tmp/wt/new.txt"; printf 'scratch\n' > "$tmp/wt/.fxa-notes.md"
echo '{"pr_title":"fix(x): keep b","pr_body":"Because b was lost."}' > "$tmp/wt/.fxa-auto-done.json"

out="$(finish_diff_only MNTOR-1 "$tmp/wt" 2>&1)"; rc=$?
p="$tmp/state/diffs/MNTOR-1.patch"
check "the run gives a patch in the state dir" "0|$p" "$rc|$out"
check "the patch has the edit and the new file" "1|1" "$(grep -c '^+b$' "$p")|$(grep -c '^+++ b/new.txt' "$p")"
check "the patch has no scratch file" "0" "$(grep -c 'fxa-' "$p")"
check "the patch applies to the base" "yes" "$(g -C "$tmp/origin.git" worktree add -q "$tmp/check" main 2>/dev/null; cd "$tmp/check" && git apply --check "$p" && echo yes)"
check "one comment names the title, the reason and the stat" "MNTOR-1|1|1|1" \
  "$(head -1 "$tmp/comment" | cut -d'|' -f1)|$(grep -c 'fix(x): keep b' "$tmp/comment")|$(grep -c 'opens no PR yet' "$tmp/comment")|$(grep -c 'new.txt' "$tmp/comment")"

g -C "$tmp/wt" stash -q -u; rm -f "$tmp/comment"
echo '{"pr_title":"fix(x): y","pr_body":"z"}' > "$tmp/wt/.fxa-auto-done.json"
check "no change is an error, with no comment and no patch" "1|no|no" \
  "$(finish_diff_only MNTOR-2 "$tmp/wt" >/dev/null 2>&1; echo $?)|$([ -f "$tmp/comment" ] && echo yes || echo no)|$([ -f "$tmp/state/diffs/MNTOR-2.patch" ] && echo yes || echo no)"
rm -f "$tmp/wt/.fxa-auto-done.json"
check "no handoff is an error" "1" "$(finish_diff_only MNTOR-3 "$tmp/wt" >/dev/null 2>&1; echo $?)"

g -C "$tmp/wt" stash -q -u 2>/dev/null; rm -f "$tmp/comment"
printf 'a\nreach me at zq7x9k.notreal@gmail.com\n' > "$tmp/wt/a.txt"
echo '{"pr_title":"fix(x): mail","pr_body":"Body names ops-secret.internal.example"}' > "$tmp/wt/.fxa-auto-done.json"
out="$(finish_diff_only MNTOR-4 "$tmp/wt" 2>/dev/null)"
check "a guard hit keeps the patch and posts only host text" "$tmp/state/diffs/MNTOR-4.patch|1|0|0" \
  "$out|$(grep -c 'personal-data check refused' "$tmp/comment")|$(grep -c 'fix(x): mail' "$tmp/comment")|$(grep -c 'zq7x9k' "$tmp/comment")"

[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
