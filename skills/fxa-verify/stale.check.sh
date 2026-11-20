#!/usr/bin/env bash
# Offline check for verify.sh --stale: only failed rows and rows of files changed after the verdict rerun.
#   bash skills/fxa-verify/stale.check.sh   (bash 4 or later, as on the runner)
set -u
[ "${BASH_VERSINFO[0]}" -ge 4 ] || { echo "skip: needs bash 4"; exit 0; }
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
V="$(cd "$(dirname "$0")" && pwd)/verify.sh"
tmp="$(cd "$(mktemp -d)" && pwd -P)" logs="$(mktemp -d)"; trap 'rm -rf "$tmp" "$logs"' EXIT
# The logs go outside the repo, or they count as files changed after the verdict.
export FXA_WORKSPACE="$tmp" TMPDIR="$logs"
sed "s#/workspace/#${tmp}/#g" "$V" > "$tmp/verify.sh"
cd "$tmp" && git init -q && git -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init && git update-ref refs/remotes/origin/main HEAD
mkdir -p pkg packages/functional-tests/tests
touch pkg/a.ts pkg/b.ts packages/functional-tests/tests/f.spec.ts notes.md
printf '%s\t%s\t%s\n' \
  "PASS" "pkg a|pkg|echo 'Tests: 1 passed'; echo ran > $tmp/ran-a; : a.ts" "PASS pkg a  1s  log" \
  "PASS" "pkg b|pkg|echo 'Tests: 1 passed'; echo ran > $tmp/ran-b; : b.ts" "PASS pkg b  1s  log" \
  "PASS" "plan functional f.spec.ts|.|echo ran > $tmp/ran-f; : tests/f.spec.ts" "PASS plan functional  1s  log" \
  "FAIL" "pkg c|.|echo 'Tests: 1 passed'; echo ran > $tmp/ran-c" "FAIL pkg c  1s  log" > "$tmp/.fxa-verify-rows.tsv"
echo old > .fxa-verify-verdict.txt; touch -t 202001010000 .fxa-verify-verdict.txt pkg/b.ts
ran() { local r="" x; for x in "$@"; do [ -e "$tmp/ran-$x" ] && r+="$x"; done; echo "$r"; }
out="$(bash "$tmp/verify.sh" --stale 2>&1)"; rc=$?
check "the changed rows and the failed row ran, the unchanged row kept" "acf" "$(ran a b c f)"
check "a changed file no row names gets a net row" 1 "$(grep -c '^ *net \.$' <<<"$out")"
check "it passes now, so exit 0" 0 "$rc"
check "the verdict says it was a partial rerun and keeps the unchanged row" "1|1" \
  "$(head -1 .fxa-verify-verdict.txt | grep -c 'reran 4 failed or changed row(s); 1 kept')|$(grep -c '^PASS pkg b' .fxa-verify-verdict.txt)"
check "the run is recorded as stale" 1 "$(grep -c '"mode":"stale"' .fxa-verify-runs.jsonl)"
rm -f "$tmp"/ran-*; touch -t 202001010000 pkg/a.ts packages/functional-tests/tests/f.spec.ts notes.md
check "with nothing changed or failed it runs nothing" "Nothing failed in the last run, and no file changed after it.|" \
  "$(bash "$tmp/verify.sh" --stale 2>&1 | tail -1)|$(ran a b c f)"
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
