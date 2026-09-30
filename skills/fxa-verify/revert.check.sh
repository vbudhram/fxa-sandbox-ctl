#!/usr/bin/env bash
# Offline check that verify.sh --revert puts every fix file back byte for byte,
# also when a test fails or the run is killed. Needs no stack.
#   bash skills/fxa-verify/revert.check.sh
set -u
[ "${BASH_VERSINFO[0]}" -ge 4 ] || { echo "skip: verify.sh needs bash 4 or later"; exit 0; }
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}

tmp="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT
verify="$(cd "$(dirname "$0")" && pwd)/verify.sh"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
g() { git -c init.defaultBranch=main -c core.hooksPath=/dev/null "$@"; }

# The functional-tests mapping calls this run.sh; the fake passes only on the fixed tree.
mkdir -p "$tmp/home/.claude/skills/fxa-functional-local"
cat >"$tmp/home/.claude/skills/fxa-functional-local/run.sh" <<EOF
case "\$(cat $tmp/mode)" in
  fail) exit 1 ;; pass) exit 0 ;;
  kill) grep -q fixed packages/app/src/a.js || { kill -TERM "\$(cat $tmp/pid)"; sleep 1; } ;;
esac
grep -q fixed packages/app/src/a.js && grep -q fixed packages/app/src/b.js && [ -f packages/app/src/new.js ] && [ ! -e packages/app/src/gone.js ]
EOF

repo="$tmp/repo"; mkdir -p "$repo/packages/app/src" "$repo/packages/functional-tests/tests"
cd "$repo"; g init -q
echo '{}' >packages/app/package.json; echo '{}' >packages/functional-tests/package.json
printf 'old a\n' >packages/app/src/a.js; printf 'old b\n' >packages/app/src/b.js; printf 'gone\n' >packages/app/src/gone.js
g add . && g commit -qm base && g update-ref refs/remotes/origin/main HEAD
g checkout -qb fix; printf 'fixed a\n' >packages/app/src/a.js; g commit -qam 'fix a'
printf 'fixed b staged\n' >packages/app/src/b.js; g add packages/app/src/b.js
printf 'fixed b\nno newline at end' >packages/app/src/b.js  # the index and the tree differ
printf 'new\n' >packages/app/src/new.js; g rm -q packages/app/src/gone.js
printf 'test\n' >packages/functional-tests/tests/x.spec.ts

snap() { g status --porcelain; g diff --cached | g hash-object --stdin
  find packages -type f | sort | while read -r f; do printf '%s %s\n' "$(g hash-object --no-filters "$f")" "$f"; done; }
want="$(snap)"
run() { echo "$1" >"$tmp/mode"; shift
  FXA_WORKSPACE="$repo" HOME="$tmp/home" bash "$verify" --revert "$@" >"$tmp/out" 2>&1 & echo $! >"$tmp/pid"; wait "$!"; }

run normal; rc=$?
check "fails without, passes with: exit 0" "0" "$rc"
check "table row" "tests/x.spec.ts FAIL PASS" "$(grep 'x.spec.ts  ' "$tmp/out" | awk '{print $1, $2, $3}' | sed 's|packages/functional-tests/||')"
check "restored byte for byte, index kept" "$want" "$(snap)"

run fail; rc=$?
check "a test that fails on both trees: exit 1" "1" "$rc"
check "restored after a failed test" "$want" "$(snap)"

run pass packages/functional-tests/tests/x.spec.ts; rc=$?
check "a test that passes without the fix is flagged" "1 1" "$rc $(grep -c 'does not prove the change' "$tmp/out")"
check "restored after a pass on both trees" "$want" "$(snap)"

run kill; rc=$?
check "killed during the run without the fix: exit 130" "130" "$rc"
check "restored after the kill" "$want" "$(snap)"

exit "$fail"
