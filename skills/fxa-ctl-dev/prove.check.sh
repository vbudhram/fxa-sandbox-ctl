#!/usr/bin/env bash
# Offline check for prove.sh: it proves a check that catches the change, rejects one that
# does not, handles a new file, and always restores the files and leaves the index alone.
#   bash skills/fxa-ctl-dev/prove.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
P="$(cd "$(dirname "$0")" && pwd)/prove.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cd "$tmp" && git init -q && git config user.email user@example.com && git config user.name t
echo 'f() { echo old; }' > x.sh; git add x.sh && git commit -qm base
echo 'f() { echo new; }' > x.sh; git add x.sh   # staged, to see the index is left alone
printf 'source ./x.sh; [ "$(f)" = new ] && echo "ok   new" || echo "FAIL old"\n' > good.check.sh
printf 'source ./x.sh; echo "ok   anything"\n' > weak.check.sh
check "a check that catches the change is proved" "0" "$(bash "$P" good.check.sh x.sh >/dev/null; echo $?)"
check "the file is restored and the index is unchanged" "new|M " "$(source ./x.sh; f)|$(git status --porcelain x.sh | cut -c1-2)"
check "a check that does not test the change is rejected" "1|yes" "$(bash "$P" weak.check.sh x.sh >/dev/null; echo $?)|$(bash "$P" weak.check.sh x.sh | grep -q 'does not test it' && echo yes)"
echo 'g() { echo hi; }' > y.sh
printf 'source ./y.sh 2>/dev/null && [ "$(g)" = hi ] && echo "ok   g" || echo "FAIL no g"\n' > new.check.sh
check "a new file: proved, and still there after" "0|yes" "$(bash "$P" new.check.sh y.sh >/dev/null; echo $?)|$([ -f y.sh ] && echo yes)"
exit "$fail"
