#!/usr/bin/env bash
# Offline check for fxa-git-ro, on a scratch repo in place of /workspace.
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
sed "s#^cd /workspace#cd $tmp/repo#" "$(cd "$(dirname "$0")" && pwd)/fxa-git-ro" > "$tmp/ro"
git init -q "$tmp/repo"; ( cd "$tmp/repo" && echo hello > a.txt && git add a.txt && git -c user.email=t@example.com -c user.name=t commit -qm first )
r() { bash "$tmp/ro" "$@" >"$tmp/out" 2>&1; echo $?; }
check "log with allowed options" "0" "$(r log --oneline -n 1)"
check "show a file at HEAD" "0|hello" "$(r show HEAD:a.txt)|$(cat "$tmp/out")"
check "grep with options" "0" "$(r grep -n -i hello)"
check "diff --output is refused, and writes nothing" "2|no" "$(r diff --output="$tmp/pwn" HEAD)|$([ -e "$tmp/pwn" ] && echo yes || echo no)"
check "log --output is refused" "2" "$(r log --output="$tmp/pwn")"
check "fetch is not a subcommand" "2" "$(r fetch --upload-pack="touch $tmp/pwn2" .)"
check "and ran nothing" "no" "$([ -e "$tmp/pwn2" ] && echo yes || echo no)"
check "grep -O (open in a pager program) is refused" "2" "$(r grep -O"touch $tmp/pwn3" hello)"
check "--ext-diff and --textconv are refused" "2|2" "$(r diff --ext-diff HEAD)|$(r log --textconv)"
check "a global option after the subcommand is refused" "2" "$(r log --exec-path=/tmp)"
check "fetch-pr takes only a number" "2|2" "$(r fetch-pr '1;id')|$(r fetch-pr 12 extra)"
check "unknown subcommands are refused" "2|2" "$(r config core.pager)|$(r checkout -f)"
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
