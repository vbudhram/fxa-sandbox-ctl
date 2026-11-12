#!/usr/bin/env bash
# Offline check that the conflict class and the host relock work on every team: the team's base
# branch (not main), Cargo.lock when the host has cargo, and package-lock.json as a source conflict.
#   bash lib/relock-base.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT
here="$(cd "$(dirname "$0")" && pwd)"
source "$(dirname "$0")/github.sh"
eval "$(grep '^_retry()' "$(dirname "$0")/config.sh")"
pipeline_require() { :; }; github_app_enabled() { return 1; }
worktree_branch_for() { printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]'; }
# The open PR of fxa-3 targets train-1; the others have none. GH_FAIL makes the PR read fail.
gh() {
  [ -z "${GH_FAIL:-}" ] || return 1
  case "$*" in *"--head fxa-3 "*) echo '[{"baseRefName":"train-1","isCrossRepository":false}]' ;; *) echo '[]' ;; esac
}
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
PIPE_RELOCK_SIGN=""; PIPE_BASE_BRANCH=master
# A cargo on PATH that only marks the lockfile it re-resolved.
mkdir -p "$tmp/bin"; printf '#!/bin/sh\necho resolved >> Cargo.lock\n' > "$tmp/bin/cargo"; chmod +x "$tmp/bin/cargo"

g() { git -c init.defaultBranch=master -c core.hooksPath=/dev/null "$@"; }
g init -q --bare "$tmp/origin.git"
g clone -q "$tmp/origin.git" "$tmp/seed" 2>/dev/null
cd "$tmp/seed"
printf 'a\n' > Cargo.lock; printf 'a\n' > package-lock.json; g add . && g commit -qm base && g push -q origin master
g checkout -qb fxa-1; printf 'branch\n' > Cargo.lock; g commit -qam one; g push -q origin fxa-1
g checkout -qb fxa-2 master; printf 'branch\n' > package-lock.json; g commit -qam two; g push -q origin fxa-2
g checkout -qb train-1 master; g push -q origin train-1
g checkout -qb fxa-3 train-1; printf 'train\n' > package-lock.json; g commit -qam three; g push -q origin fxa-3
g checkout -q master; printf 'base2\n' > Cargo.lock; printf 'base2\n' > package-lock.json; g commit -qam base2; g push -q origin master
g clone -q "$tmp/origin.git" "$tmp/repo" 2>/dev/null
PIPE_REPO="$tmp/repo"

check "a Cargo.lock conflict against master is a source conflict on a host with no cargo" "source" "$(PATH=/usr/bin:/bin gh_conflicts FXA-1 | cut -d' ' -f1)"
PATH="$tmp/bin:$PATH"
check "with cargo on the host, it is a lockfile conflict" "lockfile" "$(gh_conflicts FXA-1 | cut -d' ' -f1)"
check "package-lock.json is a source conflict" "source" "$(gh_conflicts FXA-2 | cut -d' ' -f1)"
gh_relock FXA-1 >/dev/null 2>&1; rc=$?
g -C "$tmp/repo" fetch -q origin
check "the relock merges master, takes master's Cargo.lock, and cargo re-resolves it" "0|yes|base2 resolved" \
  "$rc|$(g -C "$tmp/repo" merge-base --is-ancestor origin/master origin/fxa-1 && echo yes)|$(g -C "$tmp/repo" show origin/fxa-1:Cargo.lock | tr '\n' ' ' | sed 's/ $//')"
check "the relock refuses a package-lock.json conflict" "1" "$(gh_relock FXA-2 >/dev/null 2>&1; echo $?)"
# A PR a person moved to a release branch is checked against that branch, never the team base.
check "a PR on train-1 has train-1 as its base; a key with no PR has the team base" "train-1|master" "$(gh_pr_base FXA-3)|$(gh_pr_base FXA-2)"
check "a PR on train-1 that conflicts only with master merges clean" "" "$(gh_conflicts FXA-3)"
check "a PR base that GitHub cannot read stops the conflict check and the relock" "1|1" \
  "$(GH_FAIL=1 gh_conflicts FXA-3 >/dev/null 2>&1; echo $?)|$(GH_FAIL=1 gh_relock FXA-1 >/dev/null 2>&1; echo $?)"
check "a pipeline run on a ticket with an open PR takes that PR's base unless --base is given" "1" \
  "$(grep -c 'base="$(gh_pr_base "$key")" || return 1' "$here/../fxa-sandbox-ctl")"
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
