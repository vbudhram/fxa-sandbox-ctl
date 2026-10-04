#!/usr/bin/env bash
# Offline check for link.sh.   bash skills/fxa-jira-link/link.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
L="$(cd "$(dirname "$0")" && pwd)/link.sh"
u="$(bash "$L" --type bug --summary 'Same-password error & wrong text #2' --description $'Steps:\n1. Open /settings\n2. Use 100% the same password' --labels 'fxa-agent,bad label,ok.1')"
check "base and type: the FXA create screen as a bug" "https://mozilla-hub.atlassian.net/secure/CreateIssueDetails!init.jspa?pid=10204&issuetype=10020" "${u%%&summary=*}"
check "summary: spaces, & and # are encoded" "Same-password%20error%20%26%20wrong%20text%20%232" "$(sed -E 's/.*&summary=([^&]*).*/\1/' <<< "$u")"
check "description: newlines and % are encoded" "Steps%3A%0A1.%20Open%20%2Fsettings%0A2.%20Use%20100%25%20the%20same%20password" "$(sed -E 's/.*&description=([^&]*).*/\1/' <<< "$u")"
check "labels: only safe ones" "&labels=fxa-agent&labels=ok.1" "$(grep -o '&labels=[^&]*' <<< "$u" | tr -d '\n')"
check "types map to FXA's ids" "10007 10030 10057" "$(for t in task story spike; do bash "$L" --type "$t" --summary x | sed -E 's/.*issuetype=([0-9]+).*/\1/'; done | tr '\n' ' ' | sed 's/ $//')"
check "no summary is refused" "2" "$(bash "$L" --type bug 2>/dev/null; echo $?)"
check "an unknown type is refused" "2" "$(bash "$L" --type incident --summary x 2>/dev/null; echo $?)"
long="$(head -c 9000 /dev/zero | tr '\0' a)"
check "a long description is cut, so the link stays under 8,000 characters" "1" "$([ "$(bash "$L" --type task --summary x --description "$long" | wc -c)" -lt 8000 ] && echo 1)"
check "a description file outside /workspace is refused" "2" "$(bash "$L" --type task --summary x --description-file /etc/hosts 2>/dev/null; echo $?)"
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
