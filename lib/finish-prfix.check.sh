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
for f in finish_approve_functional_gate finish_add_reviewers finish_request_copilot_review _finish_feedback_comment _finish_feedback_pr _finish_media_to_bucket; do
  eval "$f() { echo $f >> \"\$tmp/steps\"; }"
done
_finish_release_runner() { :; }

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

# Fix-pr mode: a started fix row of a pr-label routine, and finish with the run, the PR and the head it booted at.
rt="$(db_value "INSERT INTO routines (team, data) VALUES ('fxa', json('{}')); SELECT last_insert_rowid();")"
run() { db_value "INSERT INTO routine_runs (routine_id, period, state, heads) VALUES ($rt, 'pr-90001-$1', 'started', json('{\"fix\":{\"pr\":90001}}')); SELECT last_insert_rowid();"; }
fix() { db_value "SELECT heads->'fix' FROM routine_runs WHERE id = $1;"; }
ffin() { # ffin <run> <worktree>   finish in fix-pr mode; prints the exit code
  local rc=0; FXA_APP_COMMIT_FF="$1" FXA_FIX_HEAD_SHA="$D" FXA_FINISH_PR="$PR" FXA_MEDIA_BUCKET=b _finish_push_and_pr "$2" true >/dev/null 2>"$tmp/err" || rc=$?
  echo "$rc"
}
other() { # a commit on the PR branch that another push made
  git -C "$O" commit-tree "$(git -C "$O" rev-parse "$D^{tree}")" -p "$D" -m "chore(deps): rebase" </dev/null; }

# A4, A15b: one App commit on the PR head; no gate approval, reviewers, Copilot review, media comment or upload,
# and no feedback comment. heads.fix has the claim and new_sha.
reset_origin; r1="$(run a)"; w="$(wt 'echo two > a.txt')"
rc="$(ffin "$r1" "$w")"; new="$(git -C "$O" rev-parse "$B")"
check "fix-pr mode pushes one App commit on the PR head" "0|$D" "$rc|$(git -C "$O" rev-parse "$B~1")"
check "fix-pr mode makes no other GitHub or CircleCI write" "|0|0" "$(cat "$tmp/steps")|$(grep -c 'pr comment' "$tmp/gh")|$(grep -c 'requested_reviewers' "$tmp/gh")"
check "heads.fix has the claim, the pending sha and new_sha" "1|$new|$new" "$(fix "$r1" | jq -r '"\(.pushing > 0 | if . then 1 else 0 end)|\(.pending_sha)|\(.new_sha)"')"

# A6: the ref moved, and then the token mint fails: new_sha is already written.
reset_origin; r2="$(run b)"; w="$(wt 'echo three > a.txt')"
rc="$(github_app_token() { return 1; }; ffin "$r2" "$w")"
check "a token mint that fails after the push leaves new_sha" "1|$(git -C "$O" rev-parse "$B")" "$rc|$(fix "$r2" | jq -r .new_sha)"

# A5: another commit lands between the GET and the PATCH: refused, their commit stays, why 'moved', the claim is cleared.
reset_origin; r3="$(run c)"; w="$(wt 'echo four > a.txt')"; X="$(other)"
rc="$(MOVE_AT_PATCH="$X" ffin "$r3" "$w")"
check "a branch that moves during the push: 3, their commit stays, why moved, no claim and no new_sha" "3|$X|moved|null|null|null" \
  "$rc|$(git -C "$O" rev-parse "$B")|$(fix "$r3" | jq -r '"\(.why)|\(.pushing)|\(.pending_sha)|\(.new_sha)"')"

# A5b: Dependabot rebased the branch during the agent's turn: the PR head is not the head the run booted at.
reset_origin; r4="$(run d)"; X="$(other)"; git -C "$O" update-ref "refs/heads/$B" "$X"
jq --arg x "$X" '.headRefOid = $x' "$tmp/fx/pr/90001.json" > "$tmp/x" && cp "$tmp/x" "$tmp/fx/pr/90001.rebased.json"
cp "$tmp/fx/pr/90001.json" "$tmp/fx/pr/90001.head.json"; cp "$tmp/fx/pr/90001.rebased.json" "$tmp/fx/pr/90001.json"
w="$(wt 'echo five > a.txt')"; rc="$(ffin "$r4" "$w")"
check "a PR head that moved during the turn: 3, nothing pushed, why moved" "3|$X|moved|0" \
  "$rc|$(git -C "$O" rev-parse "$B")|$(fix "$r4" | jq -r .why)|$(grep -c '^PATCH' "$tmp/api")"
cp "$tmp/fx/pr/90001.head.json" "$tmp/fx/pr/90001.json"

# A stopped run: the claim is refused, nothing is pushed.
reset_origin; r5="$(run e)"; db_exec "UPDATE routine_runs SET state = 'stopped' WHERE id = $r5;"; w="$(wt 'echo six > a.txt')"
check "a run stopped before the push: 4 and nothing pushed" "4|$D" "$(ffin "$r5" "$w")|$(git -C "$O" rev-parse "$B")"

# A38, A5c: the yarn.lock guard and the tooling guard. A refusal sets why guard:<class> and pushes nothing.
guard() { # guard <run tag> <agent edit>   exit|why|branch moved|the ERROR line's fixed text
  local r rc w; reset_origin; r="$(run "$1")"; w="$(wt "$2")"; rc="$(FXA_ALLOW_TOOLING_EDITS=1 ffin "$r" "$w")"
  echo "$rc|$(fix "$r" | jq -r '.why // ""')|$([ "$(git -C "$O" rev-parse "$B")" = "$D" ] && echo same || echo moved)|$(grep -c "The fix changes yarn.lock entries, which I do not push. Fix it by hand." "$tmp/err")"
}
check "a resolution from a GitHub tarball is refused" "1|guard:lock|same|1" \
  "$(guard g1 'sed -i.b "s#example-pkg@npm:1.3.0#example-pkg@https://codeload.github.com/x/y/tar.gz/abc#" yarn.lock && rm yarn.lock.b')"
check "a checksum change with no version change is refused" "1|guard:lock|same|1" \
  "$(guard g2 'sed -i.b "s/bbb/ccc/" yarn.lock && rm yarn.lock.b')"
check "a registry bump pushes, in the berry and the v1 lockfile formats" "0||moved|0" \
  "$(guard g3 'sed -i.b "s/1\.3\.0/1.3.1/g; s/bbb/ddd/" yarn.lock && rm yarn.lock.b && mkdir -p old && printf "\"left-pad@^1.0.0\":\n  version \"1.3.0\"\n  resolved \"https://registry.yarnpkg.com/left-pad/-/left-pad-1.3.0.tgz#abc\"\n  integrity sha512-x\n" > old/yarn.lock')"
check "a v1 entry from another host is refused" "1|guard:lock|same|1" \
  "$(guard g4 'mkdir -p old && printf "left-pad@^1.0.0:\n  version \"1.3.0\"\n  resolved \"https://evil.example/left-pad-1.3.0.tgz\"\n  integrity sha512-x\n" > old/yarn.lock')"
check "a .yarn/patches file is refused in fix-pr mode, whatever FXA_ALLOW_TOOLING_EDITS says" "1|guard:tooling|same|0" \
  "$(guard g5 'mkdir -p .yarn/patches && echo p > .yarn/patches/x.patch')"

[ "$fail" = 0 ] && echo "all ok"
exit "$fail"
