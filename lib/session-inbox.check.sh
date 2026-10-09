#!/usr/bin/env bash
# Offline check for _inbox_copy: the files a person sent in Slack, before they reach a runner.
#   bash lib/session-inbox.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
here="$(cd "$(dirname "$0")" && pwd)"
_fsize() { wc -c < "$1" | tr -d ' '; }
eval "$(sed -n '/^_inbox_copy() {/,/^}/p' "$here/session.sh")"
mkdir -p "$tmp/in" "$tmp/out"
echo shot > "$tmp/in/shot.png"; echo diff > "$tmp/in/D1.diff"; echo x > "$tmp/in/-rf"
ln -s "$tmp/in/shot.png" "$tmp/in/link.png"
check "plain files with safe names are copied; a dash name and a link are not" "2|D1.diff shot.png" \
  "$(_inbox_copy "$tmp/out" "$tmp/in/shot.png" "$tmp/in/D1.diff" "$tmp/in/-rf" "$tmp/in/link.png" 2>/dev/null)|$(ls "$tmp/out" | tr '\n' ' ' | sed 's/ $//')"
check "no file to copy: it fails" "1" "$(_inbox_copy "$tmp/out2" "$tmp/in/-rf" >/dev/null 2>&1; echo $?)"
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
