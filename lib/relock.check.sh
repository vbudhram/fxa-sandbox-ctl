#!/usr/bin/env bash
# Offline check that relock fixes a yarn.lock-only conflict and refuses anything else.
#   bash lib/relock.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}

tmp="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT
source "$(dirname "$0")/github.sh"
eval "$(grep '^_retry()' "$(dirname "$0")/config.sh")"
pipeline_require() { :; }
worktree_branch_for() { printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]'; }
pipeline_attempts() { if [ "${2:-}" = bump ]; then echo bumped >>"$tmp/attempts"; else wc -l <"$tmp/attempts" 2>/dev/null | tr -d ' ' || echo 0; fi; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
PIPE_RELOCK_SIGN=""
printf '#!/bin/sh\necho resolved-branch-dep >> yarn.lock\necho "key=${ANTHROPIC_API_KEY:-} scripts=${YARN_ENABLE_SCRIPTS:-}" >> %s/yarn-env\n' "$tmp" >"$tmp/fake-yarn"; chmod +x "$tmp/fake-yarn"
PIPE_RELOCK_CMD="$tmp/fake-yarn"

g() { git -c init.defaultBranch=main -c core.hooksPath=/dev/null "$@"; }
g init -q --bare "$tmp/origin.git"
g clone -q "$tmp/origin.git" "$tmp/seed" 2>/dev/null
cd "$tmp/seed"
printf 'a\n' >src.js; printf 'lock-base\n' >yarn.lock
g add . && g commit -qm base && g push -q origin main
g checkout -qb fxa-1; printf 'lock-branch\n' >yarn.lock; g commit -qam branch; g push -q origin fxa-1
g checkout -qb fxa-2 main; printf 'b\n' >src.js; printf 'lock-2\n' >yarn.lock; g commit -qam two; g push -q origin fxa-2
g checkout -qb fxa-3 main; printf 'lock-3\n' >yarn.lock; g commit -qam three; g push -q origin fxa-3
# fxa-4 adds a dependency that runs code at fetch time; fxa-5 bumps one within the registry.
g checkout -qb fxa-4 main; printf '{"dependencies":{"x":"exec:./x.js"}}\n' >package.json; printf 'lock-4\n' >yarn.lock; g add . && g commit -qm four; g push -q origin fxa-4
g checkout -qb fxa-5 main; printf '{"dependencies":{"x":"^1.2.3","y":"npm:z@~2.0.0"}}\n' >package.json; printf 'lock-5\n' >yarn.lock; g add . && g commit -qm five; g push -q origin fxa-5
g checkout -q main; printf 'lock-main\n' >yarn.lock; printf 'c\n' >src.js; g commit -qam main; g push -q origin main
g clone -q "$tmp/origin.git" "$tmp/repo" 2>/dev/null
PIPE_REPO="$tmp/repo"

check "lockfile conflict is classified" "lockfile" "$(gh_conflicts FXA-1 | cut -d' ' -f1)"
gh_relock FXA-1 >/dev/null 2>&1; rc=$?
check "relock succeeds" "0" "$rc"
g -C "$tmp/repo" fetch -q origin
check "branch now contains main" "yes" "$(g -C "$tmp/repo" merge-base --is-ancestor origin/main origin/fxa-1 && echo yes)"
check "old branch head kept (no force-push)" "yes" "$(g -C "$tmp/repo" merge-base --is-ancestor "$(g -C "$tmp/seed" rev-parse fxa-1)" origin/fxa-1 && echo yes)"
check "yarn.lock is main's plus the re-resolve" "lock-main resolved-branch-dep" "$(g -C "$tmp/repo" show origin/fxa-1:yarn.lock | tr '\n' ' ' | sed 's/ $//')"
check "merges clean afterwards" "" "$(gh_conflicts FXA-1)"
check "attempt recorded" "1" "$(pipeline_attempts FXA-1)"
check "temp worktree removed" "1" "$(g -C "$tmp/repo" worktree list | grep -c .)"

before="$(g -C "$tmp/repo" rev-parse origin/fxa-2)"
gh_relock FXA-2 >/dev/null 2>&1; rc=$?
check "source conflict is refused" "1" "$rc"
g -C "$tmp/repo" fetch -q origin
check "source branch untouched" "$before" "$(g -C "$tmp/repo" rev-parse origin/fxa-2)"

# With the App on, the App makes the merge commit; git neither signs nor pushes.
before="$(g -C "$tmp/repo" rev-parse origin/fxa-3)"
github_app_enabled() { true; }
github_app_commit() { printf '%s|%s|%s\n' "$2" "$3" "$5" > "$tmp/app"; git -C "$1" show :yarn.lock > "$tmp/app-lock"; echo sha; }
gh_relock FXA-3 >/dev/null 2>&1; rc=$?
check "App relock: a merge of main into the branch head" "0|fxa-3|$(g -C "$tmp/repo" rev-parse origin/main)|$before" "$rc|$(cat "$tmp/app" 2>/dev/null)"
check "App relock: the staged yarn.lock is re-resolved" "lock-main resolved-branch-dep" "$(tr '\n' ' ' < "$tmp/app-lock" | sed 's/ $//')"
g -C "$tmp/repo" fetch -q origin
check "App relock: no git push" "$before" "$(g -C "$tmp/repo" rev-parse origin/fxa-3)"

# The relock runs yarn on the agent's branch on the manager: no fetch-time code, and no controller secret in its env.
export ANTHROPIC_API_KEY=secretmark; rm -f "$tmp/yarn-env" "$tmp/app" "$tmp/attempts"
out="$(gh_relock FXA-4 2>&1 >/dev/null)"; rc=$?
check "relock refuses a dependency spec that runs code (exec:), and yarn never runs" "1|no-yarn|yes" "$rc|$([ -f "$tmp/yarn-env" ] && cat "$tmp/yarn-env" || echo no-yarn)|$(grep -q 'exec:' <<< "$out" && echo yes)"
rm -f "$tmp/yarn-env"; gh_relock FXA-5 >/dev/null 2>&1; rc=$?
check "relock of a registry bump runs yarn with no secret in its env and scripts off" "0|key= scripts=0" "$rc|$(cat "$tmp/yarn-env" 2>/dev/null)"
unset ANTHROPIC_API_KEY

exit "$fail"
