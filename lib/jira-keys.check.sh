#!/usr/bin/env bash
# Offline check of _jira_keys_for_jql (lib/jira.sh): an acli error in place of JSON is a failed Jira read, not a crash.
#   bash lib/jira-keys.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
command -v jq >/dev/null || { echo "skip: needs jq"; exit 0; }
here="$(cd "$(dirname "$0")" && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/jira-keys.XXXXXX")"; trap 'rm -rf "$tmp"' EXIT
export FXA_ERRORS_FILE="$tmp/errors.jsonl" FXA_ERRORS_URI=""

# Shaped like the controller: set -e, the ERR trap in main, a caller that reads the keys.
cat > "$tmp/prog.sh" <<EOF
#!/bin/bash
set -euo pipefail
source "$here/config.sh"; source "$here/errors.sh"; source "$here/jira.sh"
acli() { case "\$ACLI" in json) echo '[{"key":"FXA-1"},{"key":"FXA-2"}]' ;; empty) return 1 ;; *) echo "Error: unauthorized (401)" ;; esac; }
read_keys() { _jira_keys_for_jql 'project = FXA'; }
main() { set -E; trap 'errors_err_trap \$? "\$BASH_COMMAND"' ERR; "\$@"; }
main "\$@"
EOF

out="$(ACLI=json bash "$tmp/prog.sh" read_keys 2>/dev/null | tr '\n' ' ')"
check "JSON from acli gives its keys" "FXA-1 FXA-2 " "$out"
err="$(ACLI=text bash "$tmp/prog.sh" read_keys 2>&1 >/dev/null)"; rc=$?
check "an error line from acli fails the read" "1" "$rc"
check "the failure says the Jira read failed" "1" "$(grep -c 'the Jira read failed' <<< "$err")"
check "no crash is recorded" "0" "$( [ -f "$FXA_ERRORS_FILE" ] && wc -l < "$FXA_ERRORS_FILE" | tr -d ' ' || echo 0)"
check "acli that fails is a failed read too, with no crash" "1|0" \
  "$(ACLI=empty bash "$tmp/prog.sh" read_keys >/dev/null 2>&1; echo "$?")|$( [ -f "$FXA_ERRORS_FILE" ] && wc -l < "$FXA_ERRORS_FILE" | tr -d ' ' || echo 0)"
exit "$fail"
