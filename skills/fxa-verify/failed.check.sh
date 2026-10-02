#!/usr/bin/env bash
# Offline check for verify.sh --failed: only last time's FAIL and NONE rows rerun.
#   bash skills/fxa-verify/failed.check.sh   (bash 4 or later, as on the runner)
set -u
[ "${BASH_VERSINFO[0]}" -ge 4 ] || { echo "skip: needs bash 4"; exit 0; }
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
V="$(cd "$(dirname "$0")" && pwd)/verify.sh"
tmp="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT
export FXA_WORKSPACE="$tmp"
# verify.sh writes its records under /workspace; point that at the test dir.
sed "s#/workspace/#${tmp}/#g" "$V" > "$tmp/verify.sh"
cd "$tmp" && git init -q && git -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init && git update-ref refs/remotes/origin/main HEAD
echo x > a.txt   # one changed file, so the planner does not stop early
printf '%s\t%s\t%s\n' \
  "PASS" "pkg-a unit|.|echo 'Tests: 1 passed' > $tmp/ran-a" "PASS pkg-a unit  1s  log" \
  "FAIL" "pkg-b unit|.|echo 'Tests: 1 passed'; echo ran > $tmp/ran-b" "FAIL pkg-b unit  1s  log" \
  "CI"   "plan CI: e2e|.|true" "CI   plan CI: e2e  left to CI" > "$tmp/.fxa-verify-rows.tsv"
out="$(bash "$tmp/verify.sh" --failed 2>&1)"; rc=$?
check "only the failed row ran" "no|yes" "$([ -e "$tmp/ran-a" ] && echo yes || echo no)|$([ -e "$tmp/ran-b" ] && echo yes || echo no)"
check "it passes now, so exit 0" 0 "$rc"
check "the verdict keeps the passed and CI rows and says it was a rerun" "1|PASS pkg-a|CI|PASS pkg-b" \
  "$(head -1 "$tmp/.fxa-verify-verdict.txt" | grep -c 'reran 1 failed row(s); 2 kept')|$(grep -o '^PASS pkg-a' "$tmp/.fxa-verify-verdict.txt")|$(grep -o '^CI' "$tmp/.fxa-verify-verdict.txt")|$(grep -o '^PASS pkg-b' "$tmp/.fxa-verify-verdict.txt")"
check "a second --failed finds nothing to rerun" "Nothing failed in the last run." "$(bash "$tmp/verify.sh" --failed 2>&1 | tail -1)"
rm -f "$tmp/.fxa-verify-rows.tsv"
check "with no earlier run it says so" 2 "$(bash "$tmp/verify.sh" --failed >/dev/null 2>&1; echo $?)"
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
