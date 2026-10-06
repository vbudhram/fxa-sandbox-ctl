#!/usr/bin/env bash
# Offline check for verify.sh's format row: it writes Prettier on the changed files and
# passes, naming them, and fails only when Prettier cannot parse a file.
#   bash skills/fxa-verify/format.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
# Build the row's command from verify.sh itself.
add() { cmd="$3"; }; rel() { shift; printf '%s ' "$@"; }
p=. pre="" fs=(ugly.ts clean.ts)
eval "$(grep -m1 'add "${pre}$p format"' "$(dirname "$0")/verify.sh")"
# A stub Prettier: "ugly" files differ and get fixed; a "broken" file cannot be parsed.
mkdir -p "$tmp/bin"; cat > "$tmp/bin/npx" <<'NPX'
#!/bin/bash
shift  # prettier
mode="$1"; shift; [ "$1" = --ignore-unknown ] && shift
for f in "$@"; do grep -q broken "$f" && { echo "SyntaxError in $f" >&2; exit 2; }; done
if [ "$mode" = --list-different ]; then r=0; for f in "$@"; do grep -q ugly "$f" && { echo "$f"; r=1; }; done; exit $r; fi
for f in "$@"; do sed -i.bak 's/ugly/pretty/' "$f"; rm -f "$f.bak"; done
NPX
chmod +x "$tmp/bin/npx"; cd "$tmp"
run() { (PATH="$tmp/bin:$PATH"; eval "$cmd") 2>&1; echo "rc=$?"; }
echo ugly > ugly.ts; echo fine > clean.ts
check "a file Prettier changes is written and named, and the row passes" "formatted: ugly.ts|rc=0|pretty" "$(run | paste -sd'|' -)|$(cat ugly.ts)"
check "clean files: nothing to say, the row passes" "rc=0" "$(run)"
echo broken > clean.ts
check "a file Prettier cannot parse fails the row" "rc=2" "$(run | tail -1)"
exit "$fail"
