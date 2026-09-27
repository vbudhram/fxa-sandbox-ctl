#!/usr/bin/env bash
# Offline check for the error log and the ERR trap.
#   bash lib/errors.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
here="$(cd "$(dirname "$0")" && pwd -P)"

# A program shaped like the controller: set -e, the trap in main, and the bug
# that ended an Open PR job on 2026-09-27 (a grep with no match in a handler).
cat > "$tmp/prog.sh" <<EOF
#!/bin/bash
set -euo pipefail
source "$here/errors.sh"
handler() { local last; last="\$(grep -E '^ERROR' "$tmp/empty.log" | tail -1)"; echo "not reached"; }
job() { false || { handler; return 1; }; }
expected() { local x; x="\$(grep nothing "$tmp/empty.log" | head -1 || true)"; return 0; }
main() { _ERR_CONTEXT="\$*"; set -E; trap 'errors_err_trap \$? "\$BASH_COMMAND"' ERR; expected; "\$@"; }
main "\$@"
EOF
: > "$tmp/empty.log"
export FXA_ERRORS_FILE="$tmp/errors.jsonl" FXA_ERRORS_URI=""

err="$(bash "$tmp/prog.sh" job agent-abc123 2>&1 >/dev/null)"; rc=$?
check "crash still exits non-zero" "1" "$rc"
check "crash is named on stderr" "1" "$(grep -c 'unexpected failure (exit 1) at prog.sh:[0-9]* handler' <<< "$err")"
check "one crash recorded" "1" "$(wc -l < "$FXA_ERRORS_FILE" | tr -d ' ')"
check "crash fields" "ctl|crash|agent-abc123|handler" "$(jq -r '"\(.source)|\(.kind)|\(.key)|\(.where | split(" ")[1])"' "$FXA_ERRORS_FILE")"

rm -f "$FXA_ERRORS_FILE"
bash "$tmp/prog.sh" expected >/dev/null 2>&1
check "a handled grep miss records nothing" "0" "$( [ -f "$FXA_ERRORS_FILE" ] && wc -l < "$FXA_ERRORS_FILE" | tr -d ' ' || echo 0)"

# Signatures group the same bug across sessions and lines.
source "$here/errors.sh"
a="$(errors_sig "x.sh:10 f" "agent-aaaa11 failed at /tmp/a/b line 7")"
b="$(errors_sig "x.sh:99 f" "agent-bbbb22 failed at /var/c line 8")"
c="$(errors_sig "x.sh:10 g" "agent-aaaa11 failed at /tmp/a/b line 7")"
check "same bug, same signature" "$a" "$b"
check "other function, other signature" "1" "$( [ "$a" != "$c" ] && echo 1 || echo 0)"

# Grouping, resolve, and reopen.
ERRORS_FILE="$tmp/e2.jsonl"; ERRORS_RESOLVED="$tmp/e2-resolved.json"; ERRORS_URI=""
errors_record session pr_failed agent-aaaa11 session-finish "no handoff" ""
errors_record session pr_failed agent-bbbb22 session-finish "no handoff" ""
sig="$(jq -r .sig "$ERRORS_FILE" | head -1)"
check "grouped with a count" "2|open" "$(cmd_errors --json | jq -r '.[0] | "\(.count)|\(.status)"')"
cmd_errors resolve "$sig" "fixed in abc" >/dev/null
check "resolve hides it" "No open errors." "$(cmd_errors)"
sleep 1; errors_record session pr_failed agent-cccc33 session-finish "no handoff" ""
check "seen again, it reopens" "reopened" "$(cmd_errors --json | jq -r '.[0].status')"

[ "$fail" = 0 ] && echo "all ok"
exit "$fail"
