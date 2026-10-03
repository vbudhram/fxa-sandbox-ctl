#!/usr/bin/env bash
# Offline check for check.sh on a scratch repo with an origin/main.
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
C="$(cd "$(dirname "$0")" && pwd)/check.sh"
r="$tmp/repo"; mkdir -p "$r"; cd "$r" || exit 1
git init -q; g() { git -c user.email=t@example.com -c user.name=t "$@"; }
mkdir -p packages/app/src _scripts packages/functional-tests/tests/signin lib/senders
printf 'export function keep() {}\nexport function gone() {}\n' > packages/app/src/a.ts
printf "const frozen = [\n  'lib/senders/',\n];\n" > _scripts/check-frozen.ts
echo old > lib/senders/mail.ts
printf "test.describe('severity-1 sign in', () => {});\n" > packages/functional-tests/tests/signin/old.spec.ts
g add -A; g commit -qm base; git update-ref refs/remotes/origin/main HEAD
# The change.
printf 'export function keep() {}\n' > packages/app/src/a.ts
echo new > lib/senders/mail.ts
printf "fireEvent.click(screen.getByTestId('x'));\n" > packages/app/src/a.test.tsx
printf "test.describe('new flow', () => {});\n" > packages/functional-tests/tests/signin/new.spec.ts
g add packages/app/src/a.ts lib/senders/mail.ts; g commit -qm change
echo '{}' > .fxa-test-plan.json; printf 'plan  unit a.test  PASS\nplan  flow new  FAIL\n' > .fxa-verify-verdict.txt
sleep 1; touch packages/app/src/a.ts
out="$(bash "$C" "$r")"
has() { grep -c -- "$1" <<< "$out" | tr -d ' '; }
check "the untracked test is listed" "1" "$(grep -c '^  packages/app/src/a.test.tsx$' <<< "$(sed -n '/Untracked/,/==/p' <<< "$out")")"
check "check 1: fireEvent/ByTestId in a new react test" "1" "$(has '! react test uses')"
check "check 3: a removed export asks for tsc on its package" "1" "$(has '! a removed export or changed signature in packages/app: run npx tsc --noEmit -p packages/app/tsconfig.json')"
check "check 4: a frozen path" "1" "$(has '! frozen path (yarn check:frozen refuses the commit): lib/senders/mail.ts')"
check "check 6: a FAIL in the verdict, and code newer than it" "1|1" "$(has '! verdict: plan  flow new  FAIL')|$(has '! code changed after the verdict')"
check "check 7: a new spec without the tag its neighbour has" "1" "$(has '! packages/functional-tests/tests/signin/new.spec.ts has no severity-N or #smoke tag')"
check "the count" "1" "$(has '== 6 item(s) need attention')"
# A clean change: nothing flagged.
g add -A >/dev/null; g commit -qm all >/dev/null; git update-ref refs/remotes/origin/main HEAD; rm -f .fxa-test-plan.json
echo "// note" >> packages/app/src/a.ts
check "a clean change flags nothing" "1" "$(bash "$C" "$r" | grep -c '== 0 item(s) need attention')"
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
