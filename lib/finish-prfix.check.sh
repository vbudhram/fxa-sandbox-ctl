#!/usr/bin/env bash
# Offline check of finish on a dependency PR that a session checked out (task --checkout), and of fix-pr mode
# (FXA_APP_COMMIT_FF=<run>). GitHub's git API is a fake on a local bare repo; gh is the shared fake of lib/testdata/prfix.
#   bash lib/finish-prfix.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
command -v sqlite3 >/dev/null || { echo "skip: needs sqlite3"; exit 0; }
here="$(cd "$(dirname "$0")" && pwd -P)"
tmp="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT
export FXA_DB="$tmp/fxa.db" FXA_DB_BACKUP_URI="" GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
source "$here/finish.sh"; source "$here/github.sh"; source "$here/db.sh"; source "$here/routines.sh"
db_init >/dev/null
_retry() { "$@"; }
g() { git -c init.defaultBranch=main -c core.hooksPath=/dev/null "$@"; }

# The fake gh, on a copy of the fixture: PR 90001 is the checked-out PR, and 90006 is a fork PR with the same branch.
B="dependabot/npm_and_yarn/example-pkg-1.3.0" PR=https://github.com/mozilla/fxa/pull/90001
cp -R "$here/testdata/prfix" "$tmp/fx"
export PATH="$here/testdata/prfix/bin:$PATH" PRFIX_DIR="$tmp/fx" PRFIX_GH_LOG="$tmp/gh"

# origin: main at M, and the PR branch with Dependabot's commit D.
O="$tmp/origin.git"; g init -q --bare "$O"; g clone -q "$O" "$tmp/seed" 2>/dev/null; cd "$tmp/seed"
printf '"example-pkg@npm:^1.2.3":\n  version: 1.2.3\n  resolution: "example-pkg@npm:1.2.3"\n  checksum: 10c0/aaa\n' > yarn.lock
echo one > a.txt; g add . && g commit -qm M && g push -q origin HEAD:main; M="$(git rev-parse HEAD)"
g checkout -qb "$B"; sed -i.bak 's/1\.2\.3"$/1.3.0"/; s/version: 1.2.3/version: 1.3.0/; s/aaa/bbb/' yarn.lock; rm yarn.lock.bak
GIT_AUTHOR_NAME='dependabot[bot]' g commit -qam "chore(deps): bump example-pkg"; D="$(git rev-parse HEAD)"; g push -q origin "$B"
jq --arg d "$D" '.headRefOid = $d' "$tmp/fx/pr/90001.json" > "$tmp/x" && mv "$tmp/x" "$tmp/fx/pr/90001.json"
jq --arg b "$B" '.headRefName = $b' "$tmp/fx/pr/90006.json" > "$tmp/x" && mv "$tmp/x" "$tmp/fx/pr/90006.json"
g clone -q "$O" "$tmp/host" 2>/dev/null

# _gh_app_api: GitHub's git API on the bare repo. A PATCH with force:false refuses a move that is not a fast forward.
# MOVE_AT_PATCH=<sha> moves the branch there first: another push lands between the GET and the PATCH.
_gh_app_api() {
  local body p sha e idx; body="$(cat)"; printf '%s %s %s\n' "$1" "$2" "$body" >> "$tmp/api"
  p="${2#git/ref/heads/}"; p="${p#git/refs/heads/}"; p="$(printf '%b' "${p//%/\\x}")"
  case "$1 $2" in
    "POST git/blobs") jq -r .content <<< "$body" | base64 -d | git -C "$O" hash-object -w --stdin | jq -Rc '{sha: .}' ;;
    "POST git/trees") idx="$tmp/idx"; rm -f "$idx"; GIT_INDEX_FILE="$idx" git -C "$O" read-tree "$(jq -r .base_tree <<< "$body")"
      while IFS=$'\t' read -r e sha mode; do
        if [ -z "$sha" ]; then GIT_INDEX_FILE="$idx" git -C "$O" update-index --force-remove "$e"
        else GIT_INDEX_FILE="$idx" git -C "$O" update-index --add --cacheinfo "$mode,$sha,$e"; fi
      done < <(jq -r '.tree[] | [.path, (.sha // ""), .mode] | @tsv' <<< "$body")
      GIT_INDEX_FILE="$idx" git -C "$O" write-tree | jq -Rc '{sha: .}' ;;
    "POST git/commits") GIT_AUTHOR_NAME='fxa-agent[bot]' git -C "$O" commit-tree "$(jq -r .tree <<< "$body")" \
        $(jq -r '.parents[] | "-p " + .' <<< "$body") -m "$(jq -r .message <<< "$body")" | jq -Rc '{sha: .}' ;;
    "GET git/ref/heads/"*) sha="$(git -C "$O" rev-parse -q --verify "refs/heads/$p")" || return 22; jq -nc --arg s "$sha" '{object: {sha: $s}}' ;;
    "PATCH git/refs/heads/"*)
      [ -z "${MOVE_AT_PATCH:-}" ] || git -C "$O" update-ref "refs/heads/$p" "$MOVE_AT_PATCH"
      sha="$(jq -r .sha <<< "$body")"
      if [ "$(jq -r .force <<< "$body")" != true ] && ! git -C "$O" merge-base --is-ancestor "refs/heads/$p" "$sha"; then
        echo '{"message":"Update is not a fast forward"}'; return 22; fi
      git -C "$O" update-ref "refs/heads/$p" "$sha" && jq -nc --arg s "$sha" '{object: {sha: $s}}' ;;
    *) echo '{}' ;;
  esac
}
github_app_enabled() { true; }
github_app_token() { echo t-app; }
worktree_git_ok() { :; }
_finish_check_frozen() { :; }
# The steps that write to GitHub or CircleCI outside the push, recorded.
for f in finish_approve_functional_gate finish_add_reviewers finish_request_copilot_review _finish_feedback_comment _finish_feedback_pr _finish_media_to_bucket _finish_release_runner; do
  eval "$f() { echo $f >> \"\$tmp/steps\"; }"
done

# wt <agent edit command>   The host worktree as session_checkout makes it: at main, the tracking ref at the PR head,
# and the runner's files (the PR head plus the agent's edit) on top. Prints its path.
n=0
wt() {
  n=$((n + 1)); local w="$tmp/wt$n"
  g -C "$tmp/host" fetch -q origin; g -C "$tmp/host" worktree add -q -B "$B" "$w" "$M" 2>/dev/null
  g -C "$tmp/host" update-ref "refs/remotes/origin/$B" "${HEAD_AT:-$D}"
  g -C "$tmp/host" archive "${HEAD_AT:-$D}" | tar -x -C "$w"
  (cd "$w" && eval "$1")
  jq -nc --arg b "$B" '{issue: "", branch: $b, pr_title: "fix(deps): adapt to example-pkg 1.3.0", pr_body: "Adapts the code to example-pkg 1.3.0.", media_paths: ["/workspace/.fxa-auto-media/shot.png"]}' > "$w/.fxa-auto-done.json"
  mkdir -p "$w/.fxa-auto-media"; : > "$w/.fxa-auto-media/shot.png"
  echo "$w"
}
reset_origin() { git -C "$O" update-ref "refs/heads/$B" "$D"; : > "$tmp/api"; : > "$tmp/gh"; : > "$tmp/steps"; }

# A3, A4: the checked-out PR is updated, not the fork PR with the same branch, and Dependabot's commit stays.
reset_origin; w="$(wt 'echo two > a.txt')"
out="$(FXA_FINISH_PR="$PR" _finish_push_and_pr "$w" true 2>"$tmp/err")"; rc=$?
check "finish updates the checked-out PR, not the fork PR with the same branch name" "0|$PR" "$rc|$out"
check "the PR keeps Dependabot's commit with its SHA, plus one App commit with only the agent's change" "$D dependabot[bot]|fxa-agent[bot] $D a.txt" \
  "$(git -C "$O" log --reverse --format='%H %an' "$M..$B" | head -1)|$(git -C "$O" log -1 --format='%an %P' "$B") $(git -C "$O" diff --name-only "$D" "$B" | paste -sd, -)"

[ "$fail" = 0 ] && echo "all ok"
exit "$fail"
