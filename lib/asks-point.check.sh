#!/usr/bin/env bash
# The point ask (lib/asks.sh): one cherry-pick -x commit per source commit onto point/<next tag>, on a scratch repo.
# The App's push and gh are stubbed. No network.
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
source "$here/config.sh"
export FXA_SESSION_STORE_URI="" FXA_SESSION_BACKUP_URI=""
FXA_SESSION_DIR="$tmp" source "$here/session.sh"
source "$here/trees.sh"
source "$here/turn-words.sh"
source "$here/worktree.sh"
source "$here/asks.sh"
SESSION_DIR="$tmp"
_session_db_sync() { :; }
export GIT_AUTHOR_NAME=Ana GIT_AUTHOR_EMAIL=ana@example.com GIT_COMMITTER_NAME=Ana GIT_COMMITTER_EMAIL=ana@example.com
PIPE_PROFILE=fxa-private PIPE_REPO_SLUG=mozilla/fxa-private PIPE_RELEASE_WORKFLOW=release-stage.yml FXA_REPO="$tmp/r"
github_app_enabled() { :; }; github_app_token() { echo tok; }
# The App's push: the staged index as one commit on <parent>, pushed to the branch.
github_app_commit() {
  local c; c="$(git -C "$1" commit-tree "$(git -C "$1" write-tree)" -p "$3" -m "$4")" && git -C "$1" push -q -f origin "$c:refs/heads/$2" && git -C "$1" reset -q --soft "$c" && echo "$c"
}
# The PR create is never retried, so it calls the binary (command gh): stub it on PATH.
mkdir "$tmp/bin"; printf '#!/bin/sh\necho "$*" >> "%s/gh"\necho https://github.com/mozilla/fxa-private/pull/9\n' "$tmp" > "$tmp/bin/gh"; chmod +x "$tmp/bin/gh"
PATH="$tmp/bin:$PATH"

# main: A (new file), B, C, D (one file each), and a merge M. train-350: T (C's file, another way) and D's change, tagged up to v1.350.1.
git init -q --bare "$tmp/o.git"; git clone -q "$tmp/o.git" "$tmp/r" 2>/dev/null; cd "$tmp/r" || exit 1
ed() { printf '%s\n' "$2" > "$1"; git add "$1"; git commit -qm "$3"; }
ed b.txt b "base"; ed c.txt c "base c"; ed d.txt d "base d"; git branch -q -M main; base="$(git rev-parse HEAD)"
git checkout -q -b train-350; ed c.txt T "fix(t): T"; ed d.txt D "fix(d): D on the train"
git tag v1.350.0 "$base"; git tag v1.350.1
git checkout -q main
ed g.txt g "feat(a): A"; A="$(git rev-parse HEAD)"
ed b.txt B "fix(b): B"; B="$(git rev-parse HEAD)"
ed c.txt C "fix(c): C"; C="$(git rev-parse HEAD)"
ed d.txt D "fix(d): D"; D="$(git rev-parse HEAD)"
git checkout -q -b side; ed h.txt h "feat(x): X"; X="$(git rev-parse HEAD)"
git checkout -q main; git merge -q --no-ff -m "Merge side" side; M="$(git rev-parse HEAD)"; git branch -q -D side
git reset -q --hard "$D"; git push -q origin main train-350 --tags 2>/dev/null
git checkout -q --detach; head="$(git rev-parse origin/train-350 2>/dev/null || git rev-parse train-350)"
cd "$here" || exit 1

check "the inputs parse, and a bad one is refused" "350 ${A:0:12} ${B:0:9}|1|1|1" \
  "$(_ask_point_inputs "point train=350 commits=${A:0:12},${B:0:9}")|$(_ask_point_inputs 'point train=350 commits=xyz' | grep -c 'commits=<sha>')|$(_ask_point_inputs 'point commits=abcdef1' | grep -c 'point train=<N>')|$(_ask_point_inputs 'point train=350 commits=abcdef1 base=main' | grep -c 'base is not an input')"
check "a non-admin gets the refusal, and an admin's words alone never run it: it takes a card" "1|0|1" \
  "$(asks_gate 0 Bo "point train=350 commits=${A}" >/dev/null; echo $?)|$(asks_gate 1 Ana "point train=350 commits=${A}" >/dev/null; echo $?)|$(_asks_words k 0 "point train=350 commits=${A}"; echo $?)"
check "a commit that is not on main or another train, or a merge, is refused" "1|1" \
  "$(_ask_point "point train=350 commits=${X:0:10}" Ana | grep -c 'not on main or on another train')|$(_ask_point "point train=350 commits=${M:0:10}" Ana | grep -c 'merge or root commit')"
: > "$tmp/gh"
got="$(_ask_point "point train=350 commits=${A:0:10},${C:0:10}" Ana)"
check "a conflict stops before any push and names the file" "1|1|0|0" \
  "$(grep -c "${C:0:12} conflicts with train-350 in c.txt" <<< "$got")|$(grep -c 'Nothing was pushed' <<< "$got")|$(git -C "$tmp/o.git" branch --list 'point/*' | grep -c .)|$(grep -c . "$tmp/gh")"
check "the card names the branch, the train head and each commit" "mozilla/fxa-private point/v1.350.2 from train-350 at ${head:0:12}: ${A:0:12} ${D:0:12} ${B:0:12}" \
  "$(_asks_target k "point train=350 commits=${A:0:10},${D:0:10},${B:0:10}")"
got="$(_ask_point "point train=350 commits=${A:0:10},${D:0:10},${B:0:10}" Ana)"
tip="$(git -C "$tmp/o.git" rev-parse point/v1.350.2)"
check "each new commit is its own cherry-pick -x on the train head, and one already there is skipped" \
  "2|${head}|1|1|${A}|${B}|g|B T D" \
  "$(git -C "$tmp/o.git" rev-list --count "${head}..${tip}")|$(git -C "$tmp/o.git" rev-parse "${tip}~2")|$(grep -c "Skipped, already on the train: ${D:0:12}" <<< "$got")|$(grep -c "sha=${tip} dry_run=true" <<< "$got")|$(git -C "$tmp/o.git" log -1 --format=%B "${tip}~1" | sed -n 's/^(cherry picked from commit \(.*\))$/\1/p')|$(git -C "$tmp/o.git" log -1 --format=%B "$tip" | sed -n 's/^(cherry picked from commit \(.*\))$/\1/p')|$(git -C "$tmp/o.git" show "${tip}:g.txt")|$(for f in b c d; do git -C "$tmp/o.git" show "${tip}:${f}.txt"; done | paste -sd' ' -)"
check "one draft PR into the train, and the host's worktree is gone" "1|1|1" \
  "$(grep -c 'pr create -R mozilla/fxa-private --draft --base train-350 --head point/v1.350.2 --title chore(release): point release v1.350.2' "$tmp/gh")|$(grep -c 'pull/9 (draft) into train-350' <<< "$got")|$(git -C "$tmp/r" worktree list | grep -c .)"
check "a second ask for the same tag is refused" "1" "$(_ask_point "point train=350 commits=${A:0:10}" Ana | grep -c 'point/v1.350.2 already exists')"
exit $fail
