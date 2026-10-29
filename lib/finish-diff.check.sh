#!/usr/bin/env bash
# Offline check for finish_diff_only: a read-only profile's run becomes a patch and one comment.
#   bash lib/finish-diff.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^finish_diff_only() {/,/^}/p;/^finish_done_file_path() {/,/^}/p;/^_finish_pii_guard() {/,/^}/p;/^_finish_push_and_pr() {/,/^}/p;/^_finish_env_gaps() {/,/^}/p' "$here/finish.sh")"
FINISH_LIB_DIR="$here"
FXA_DONE_FILENAME=.fxa-auto-done.json PIPE_STATE_DIR="$tmp/state" PIPE_PROFILE=monitor FXA_WORKTREE_BASE=main
jira_comment() { printf '%s|%s\n' "$1" "$2" > "$tmp/comment"; }
jira_attach() { printf '%s %s\n' "$1" "$2" >> "$tmp/attached"; [ -z "${ATTACH_FAILS:-}" ]; }
g() { git -c init.defaultBranch=main -c user.name=t -c user.email=t@example.com "$@"; }

g init -q --bare "$tmp/origin.git"; g clone -q "$tmp/origin.git" "$tmp/wt" 2>/dev/null
printf 'a\n' > "$tmp/wt/a.txt"; g -C "$tmp/wt" add a.txt; g -C "$tmp/wt" commit -qm init; g -C "$tmp/wt" push -q origin main
printf 'a\nb\n' > "$tmp/wt/a.txt"; printf 'new\n' > "$tmp/wt/new.txt"; printf 'scratch\n' > "$tmp/wt/.fxa-notes.md"
echo '{"pr_title":"fix(x): keep b","pr_body":"Because b was lost.","commit_body":"Because b was lost.\n\nCloses MNTOR-1"}' > "$tmp/wt/.fxa-auto-done.json"

out="$(finish_diff_only MNTOR-1 "$tmp/wt" 2>&1)"; rc=$?
p="$tmp/state/diffs/MNTOR-1.patch"
check "the run gives a patch in the state dir" "0|$p" "$rc|$out"
check "the patch has the edit and the new file" "1|1" "$(grep -c '^+b$' "$p")|$(grep -c '^+++ b/new.txt' "$p")"
check "the patch has no scratch file" "0" "$(grep -c 'fxa-' "$p")"
check "the patch applies to the base" "yes" "$(g -C "$tmp/origin.git" worktree add -q "$tmp/check" main 2>/dev/null; cd "$tmp/check" && git apply --check "$p" && echo yes)"
check "git am makes one commit with the run's subject and body" "fix(x): keep b|Closes MNTOR-1|b new.txt" \
  "$(cd "$tmp/check" && git checkout -q -- . && git -c user.name=t -c user.email=t@example.com am -q "$p" && git log -1 --format=%s)|$(cd "$tmp/check" && git log -1 --format=%b | grep -o 'Closes MNTOR-1')|$(cd "$tmp/check" && git show --format= --name-only HEAD | sed 's/a.txt/b/' | paste -sd' ' -)"
check "the patch is attached to the ticket, and the comment says how to apply it" "MNTOR-1 $p|1" \
  "$(cat "$tmp/attached")|$(grep -c 'git am MNTOR-1.patch' "$tmp/comment")"
check "one comment in an info panel names the title, the size and the next step, with no PR body" "MNTOR-1|::info
**Patch ready for review**
- Change: fix(x): keep b
- Patch: attached as \`MNTOR-1.patch\`. The monitor pipeline opens no PR yet.
- Size: 2 files changed, 2 insertions(+)
**Next:** A person reviews the patch and applies it with \`git am MNTOR-1.patch\`." "$(cat "$tmp/comment")"

# A files list in the handoff: only the listed files and the deletions ship; no list ships as before (above).
printf 'plan\n' > "$tmp/wt/.sync-test-plan.json"; printf 'stray\n' > "$tmp/wt/stray.log"
jq '.files = {"a.txt": "the fix"}' "$tmp/wt/.fxa-auto-done.json" > "$tmp/d.json" && cp "$tmp/d.json" "$tmp/wt/.fxa-auto-done.json"
finish_diff_only MNTOR-1 "$tmp/wt" >/dev/null 2>&1
check "with a files list the patch has only the listed file" "a.txt" "$(grep '^+++ b/' "$p" | sed 's#^+++ b/##' | paste -sd' ' -)"
eval "$(sed -n '/^_finish_scope() {/,/^}/p' "$here/finish.sh")"
g -C "$tmp/wt" add -A; g -C "$tmp/wt" rm -q --cached a.txt >/dev/null; g -C "$tmp/wt" add a.txt
check "the PR path unstages what the list does not name" "a.txt" "$(_finish_scope "$tmp/wt" "$tmp/wt/.fxa-auto-done.json" 2>/dev/null; g -C "$tmp/wt" diff --cached --name-only | grep -v '^\.fxa-' | paste -sd' ' -)"
g -C "$tmp/wt" reset -q; rm -f "$tmp/wt/.sync-test-plan.json" "$tmp/wt/stray.log"
jq 'del(.files)' "$tmp/wt/.fxa-auto-done.json" > "$tmp/d.json" && cp "$tmp/d.json" "$tmp/wt/.fxa-auto-done.json"
ATTACH_FAILS=1 finish_diff_only MNTOR-1 "$tmp/wt" >/dev/null 2>&1
check "a failed attach points to the patch on the pipeline host" "1|0" "$(grep -c "on the pipeline host, at \`diffs/MNTOR-1.patch\`" "$tmp/comment")|$(grep -c 'git am' "$tmp/comment")"
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
check "a guard hit attaches nothing" "0" "$(grep -c MNTOR-4 "$tmp/attached")"
check "a guard hit keeps the patch and posts only host text, in a warning panel" "$tmp/state/diffs/MNTOR-4.patch|MNTOR-4|::warning|1|0|0" \
  "$out|$(head -1 "$tmp/comment")|$(grep -c 'personal-data check refused' "$tmp/comment")|$(grep -c 'fix(x): mail' "$tmp/comment")|$(grep -c 'zq7x9k' "$tmp/comment")"

g -C "$tmp/wt" stash -q -u 2>/dev/null; rm -f "$tmp/comment"
printf 'dash\n' > "$tmp/wt/-R"
echo '{"pr_title":"fix(x): dash","pr_body":"A dash file."}' > "$tmp/wt/.fxa-auto-done.json"
finish_diff_only MNTOR-5 "$tmp/wt" >/dev/null 2>&1
check "a file whose name starts with a dash is in the patch" "1" "$(grep -c '^+++ b/-R' "$tmp/state/diffs/MNTOR-5.patch")"

# `fxa-sandbox-ctl finish` on a read-only profile: the patch, never a push.
mkdir -p "$tmp/bin"; printf '#!/bin/sh\necho "$@" >> %s/gh-calls\n' "$tmp" > "$tmp/bin/gh"; chmod +x "$tmp/bin/gh"
PATH="$tmp/bin:$PATH"; git() { case "$*" in *push*) echo push >> "$tmp/pushes"; return 1 ;; esac; command git "$@"; }
g -C "$tmp/wt" checkout -q -b mntor-6
echo '{"issue":"MNTOR-6","pr_title":"fix(x): ro","pr_body":"Read-only."}' > "$tmp/wt/.fxa-auto-done.json"
out="$(PIPE_PR_OPEN=0 _finish_push_and_pr "$tmp/wt" true 2>/dev/null)"; rc=$?
check "finish on a read-only profile keeps the patch and pushes nothing" "0|yes|no|no" \
  "$rc|$([ -s "$tmp/state/diffs/MNTOR-6.patch" ] && echo yes || echo no)|$([ -f "$tmp/pushes" ] && echo yes || echo no)|$([ -f "$tmp/gh-calls" ] && echo yes || echo no)"
echo '{"issue":"FXA-1","pr_title":"fix(x): ro","pr_body":"Read-only."}' > "$tmp/wt/.fxa-auto-done.json"
check "a handoff key that is not the slot's branch is refused" "1|no" \
  "$(PIPE_PR_OPEN=0 _finish_push_and_pr "$tmp/wt" true >/dev/null 2>&1; echo $?)|$([ -f "$tmp/state/diffs/FXA-1.patch" ] && echo yes || echo no)"
unset -f git

# jira_attach itself: the login reaches curl on stdin, never in its arguments.
eval "$(sed -n '/^jira_attach() {/,/^}/p' "$here/jira.sh"; sed -n '/^_jira_sa() /p;/^_jira_api() {/,/^}/p' "$here/config.sh")"
curl() { printf '%s\n' "$*" > "$tmp/curl-args"; cat > "$tmp/curl-in"; echo "${CODE:-200}"; }
PIPE_JIRA_BASIC="bot@example.com:tok-1234" PIPE_JIRA_SITE=https://jira.example.com
check "the attach posts the file, with the login on stdin only" "0|1|0|1" \
  "$(jira_attach MNTOR-1 "$p"; echo $?)|$(grep -c "file=@${p} https://jira.example.com/rest/api/3/issue/MNTOR-1/attachments" "$tmp/curl-args")|$(grep -c tok-1234 "$tmp/curl-args")|$(grep -c tok-1234 "$tmp/curl-in")"
check "an HTTP error, a bad key or no login fails" "1|1|1" \
  "$(CODE=403 jira_attach MNTOR-1 "$p" 2>/dev/null; echo $?)|$(jira_attach 'x;y' "$p" 2>/dev/null; echo $?)|$(PIPE_JIRA_BASIC= jira_attach MNTOR-1 "$p" 2>/dev/null; echo $?)"
unset -f curl

[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
