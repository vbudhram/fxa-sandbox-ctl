#!/usr/bin/env bash
# rep.py: one match replaces; zero or two matches write nothing.
set -euo pipefail
R="$(cd "$(dirname "$0")" && pwd)/rep.py"; T=$(mktemp -d "${TMPDIR:-/tmp}/rep.XXXXXX"); trap 'rm -rf "$T"' EXIT
printf 'a b a\nc\n' > "$T/f"
echo '[["c","d"]]' | python3 "$R" "$T/f" >/dev/null; grep -qx d "$T/f" || { echo "FAIL: one match"; exit 1; }
if echo '[["d","e"],["a","x"]]' | python3 "$R" "$T/f" 2>/dev/null; then echo "FAIL: two matches passed"; exit 1; fi
grep -qx d "$T/f" || { echo "FAIL: a miss wrote the first pair"; exit 1; }
if echo '[["zz","y"]]' | python3 "$R" "$T/f" 2>/dev/null; then echo "FAIL: no match passed"; exit 1; fi
printf 'one\n' > "$T/g"
if printf '[["%s","d","D"],["%s","nope","x"]]' "$T/f" "$T/g" | python3 "$R" 2>/dev/null; then echo "FAIL: a multi-file miss passed"; exit 1; fi
grep -qx d "$T/f" || { echo "FAIL: a multi-file miss wrote the first file"; exit 1; }
printf '[["%s","d","D"],["%s","one","two"]]' "$T/f" "$T/g" | python3 "$R" >/dev/null
grep -qx D "$T/f" && grep -qx two "$T/g" || { echo "FAIL: multi-file"; exit 1; }
echo "rep.check: ok"
