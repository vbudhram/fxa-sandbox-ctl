#!/usr/bin/env bash
# Offline check for the verify.sh output: the sibling-only label, the failure tails after the table, the next step.
#   bash skills/fxa-verify/output.check.sh   (bash 4 or later, as on the runner)
set -u
[ "${BASH_VERSINFO[0]}" -ge 4 ] || { echo "skip: needs bash 4"; exit 0; }
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
V="$(cd "$(dirname "$0")" && pwd)/verify.sh"
tmp="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT
export FXA_WORKSPACE="$tmp" TMPDIR="$tmp"
sed "s#/workspace/#${tmp}/#g" "$V" > "$tmp/verify.sh"
cd "$tmp" && git init -q && git -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init && git update-ref refs/remotes/origin/main HEAD
echo x > a.txt
# A fake Jest: --listTests names 20 related specs; a run passes.
mkdir -p bin src; touch src/a.test.ts
printf '%s\n' '#!/bin/bash' 'case " $* " in *" --listTests "*) for i in $(seq 20); do echo "x$i.spec.ts"; done ;; *) echo "Tests: 1 passed" ;; esac' > bin/fakejest; chmod +x bin/fakejest
printf '%s\t%s\t%s\n' \
  "FAIL" "pkg-a tests|.|fakejest --findRelatedTests src/a.ts" "FAIL pkg-a tests  1s  log" \
  "FAIL" "pkg-b unit|.|for i in \$(seq 30); do echo line\$i; done; exit 1" "FAIL pkg-b unit  1s  log" > "$tmp/.fxa-verify-rows.tsv"
out="$(PATH="$tmp/bin:$PATH" bash "$tmp/verify.sh" --failed 2>&1)"; rc=$?
after="$(sed -n '/^Verdict:/,$p' <<<"$out")"
check "a failed row: exit 1" 1 "$rc"
check "the sibling-only row names the count" 1 "$(grep -c 'PASS pkg-a tests (sibling only; 20 related not run)' <<<"$after")"
check "the failure tail comes after the table, last 15 lines" "1|1|0" "$(grep -c 'pkg-b unit failed; last lines' <<<"$after")|$(grep -cx line30 <<<"$after")|$(grep -cx line15 <<<"$after")"
check "the next step is --failed" 1 "$(tail -1 <<<"$out" | grep -c 'verify.sh --failed$')"
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
