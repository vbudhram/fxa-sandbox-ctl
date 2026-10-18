#!/usr/bin/env bash
# PRODUCT.md names routines: the third way in, the team admin's routine rights, and the two words.
#   bash lib/product-words.check.sh
set -u
f="$(dirname "$0")/../PRODUCT.md" fail=0
for want in '^### Three ways in' '^3\. \*\*Routines\*\*' '^\| \*\*Team admin\*\* .*routines' '^\| Routine \|' '^\| Routine run \|'; do
  if grep -qE "$want" "$f"; then echo "ok   $want"; else echo "FAIL PRODUCT.md has no line matching $want"; fail=1; fi
done
exit "$fail"
