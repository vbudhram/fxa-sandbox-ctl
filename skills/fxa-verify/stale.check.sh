#!/usr/bin/env bash
# Offline check for verify.sh --stale: the failed rows, the rows of a changed file's package, and the flows on a source change rerun.
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
fx='packages/functional-tests/tests/[x]/f.spec.ts'
mkdir -p pkg/test q 'packages/functional-tests/tests/[x]'
for p in pkg q packages/functional-tests; do echo '{}' > "$p/package.json"; done
all=(pkg/a.ts pkg/test/a.spec.ts q/x.ts "$fx" packages/functional-tests/tests/g.spec.ts notes.md pkg/package.json q/package.json packages/functional-tests/package.json)
touch "${all[@]}"
row() { printf '%s\t%s|%s|%s\n' "$1" "$2" "$3" "echo 'Tests: 1 passed'; echo ran > $tmp/ran-$4; : $5"; }
# A mirrored-spec row and a types row name no source file; a functional row names its spec as %q writes it.
{ row PASS "pkg tests" pkg A "test/a.spec.ts"; row PASS "pkg types" pkg B ""; row PASS "q tests" q Q "x.ts"
  row PASS "plan functional f.spec.ts" . F 'fxa-functional-local tests/\[x\]/f.spec.ts'
  row PASS "plan functional g.spec.ts" . G "fxa-functional-local tests/g.spec.ts"
  row PASS "plan check: k" . K ""; row FAIL "c" . C ""; } | awk -F'\t' -v OFS='\t' '{ print $1, $2, $1 " row  1s  /tmp/x/" NR ".log" }' > .fxa-verify-rows.tsv
echo old > .fxa-verify-verdict.txt
old() { touch -t 202001010000 "$@"; }
# pkg/a.ts changed during the last run: after its start, before its verdict.
old "${all[@]}"; touch -t 202101010000 .fxa-verify-start; touch -t 202201010000 pkg/a.ts; touch -t 202301010000 .fxa-verify-verdict.txt; touch notes.md
ran() { local r="" x; for x in "$@"; do [ -e "$tmp/ran-$x" ] && r+="$x"; done; echo "$r"; }
out="$(bash "$tmp/verify.sh" --stale 2>&1)"; rc=$?
check "a source change reruns its package's rows, every flow and check, and the failed row" "ABFGKC" "$(ran A B Q F G K C)"
check "a changed file in a package with no row gets a net row" 1 "$(grep -c '^ *net \.$' <<<"$out")"
check "it passes now, so exit 0" 0 "$rc"
check "the verdict says it was a partial rerun, and the kept row says its log is gone" "1|1" \
  "$(head -1 .fxa-verify-verdict.txt | grep -c 'reran 7 failed or changed row(s); 1 kept')|$(grep -c '^PASS row  1s  (kept; its log is gone)$' .fxa-verify-verdict.txt)"
check "the run is recorded as stale" 1 "$(grep -c '"mode":"stale"' .fxa-verify-runs.jsonl)"
rm -f "$tmp"/ran-*; old "${all[@]}"; touch -t 203001010000 "$fx"
check "a changed functional spec reruns only its own row" "F" "$(bash "$tmp/verify.sh" --stale >/dev/null 2>&1; ran A B Q F G K C)"
rm -f "$tmp"/ran-*; old "${all[@]}"
check "with nothing changed or failed it runs nothing" "Nothing failed in the last run, and no file changed after it.|" \
  "$(bash "$tmp/verify.sh" --stale 2>&1 | tail -1)|$(ran A B Q F G K C)"
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
