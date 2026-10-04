#!/usr/bin/env bash
# Offline check for _jira_rebase_merge: a clean merge leaves HEAD on the pushed branch tip,
# so the runner can fetch it from the remote by sha.
#   bash lib/rebase-merge.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^_jira_rebase_merge() {/,/^}/p' "$(dirname "$0")/../fxa-sandbox-ctl")"
worktree_filtered_status() { git -C "$1" status --porcelain | grep -v ' \.fxa-' || true; }
pipeline_attempts() { echo 0; }
_retry() { "$@"; }
g() { git -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false "$@"; }
git init -q --bare "$tmp/origin.git"
g clone -q "$tmp/origin.git" "$tmp/up" 2>/dev/null
( cd "$tmp/up" && g checkout -q -b main && echo a > a && g add a && g commit -qm base && g push -q origin main \
  && g checkout -q -b fxa-1 && echo b > b && g add b && g commit -qm branch && g push -q origin fxa-1 \
  && g checkout -q main && echo c > c && g add c && g commit -qm main2 && g push -q origin main )
g clone -q -b fxa-1 "$tmp/origin.git" "$tmp/wt" 2>/dev/null
tip="$(git -C "$tmp/wt" rev-parse HEAD)"
_jira_rebase_merge FXA-1 "$tmp/wt" main 2>/dev/null
check "clean merge: HEAD stays the pushed branch tip" "$tip" "$(git -C "$tmp/wt" rev-parse HEAD)"
check "clean merge: the merge is open, with main's file staged" "yes|c" "$(git -C "$tmp/wt" rev-parse -q --verify MERGE_HEAD >/dev/null && echo yes)|$(git -C "$tmp/wt" diff --cached --name-only)"
check "relaunch: an open merge of the same base resumes" "0|$tip" "$(_jira_rebase_merge FXA-1 "$tmp/wt" main 2>/dev/null; echo $?)|$(git -C "$tmp/wt" rev-parse HEAD)"
( cd "$tmp/up" && echo d > d && g add d && g commit -qm main3 && g push -q origin main )
git -C "$tmp/wt" fetch -q origin main
_jira_rebase_merge FXA-1 "$tmp/wt" main 2>/dev/null
check "relaunch: a newer base merges again" "$(git -C "$tmp/wt" rev-parse origin/main)|c d" "$(git -C "$tmp/wt" rev-parse MERGE_HEAD)|$(git -C "$tmp/wt" diff --cached --name-only | tr '\n' ' ' | sed 's/ $//')"
# An older round committed its merge here (before the fix): drop it, so HEAD is on GitHub again.
g clone -q -b fxa-1 "$tmp/origin.git" "$tmp/wt2" 2>/dev/null
( cd "$tmp/wt2" && g merge -q --no-edit origin/main 2>/dev/null )
_jira_rebase_merge FXA-1 "$tmp/wt2" main 2>/dev/null
check "an old host-only merge commit is dropped first" "$tip|yes" "$(git -C "$tmp/wt2" rev-parse HEAD)|$(git -C "$tmp/wt2" rev-parse -q --verify MERGE_HEAD >/dev/null && echo yes)"
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
