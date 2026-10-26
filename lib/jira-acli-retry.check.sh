#!/usr/bin/env bash
# Offline check that jira.sh's acli wrapper keeps the retry: one failed call must not fail the read.
#   bash lib/jira-acli-retry.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^_retry() {/p' "$(dirname "$0")/config.sh")"
eval "$(sed -n '/^_acli_once() {/,/^}/p' "$(dirname "$0")/jira.sh")"
eval "$(sed -n '/^acli() {/p' "$(dirname "$0")/jira.sh")"
eval "$(sed -n '/^jira_login_ok() {/,/^}/p' "$(dirname "$0")/jira.sh")"
_jira_sa() { return 1; }; sleep() { :; }
mkdir "$tmp/bin"
cat > "$tmp/bin/acli" <<'SH'
#!/bin/sh
n=$(( $(cat "$T/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$T/n"; echo "$HOME" > "$T/home"
[ "$n" -ge 2 ] && echo "✓ Authenticated" && exit 0
echo "✗ Error: request failed"; exit 1
SH
chmod +x "$tmp/bin/acli"; export T="$tmp" PATH="$tmp/bin:$PATH"
check "the first call fails, the retry succeeds: the login is ok" "ok|2" "$(jira_login_ok && echo ok)|$(cat "$tmp/n")"
rm -f "$tmp/n"
check "a team's acli home still reaches acli on the retry" "$tmp/team|2" "$(FXA_ACLI_HOME="$tmp/team" jira_login_ok >/dev/null; cat "$tmp/home")|$(cat "$tmp/n")"
exit $fail
