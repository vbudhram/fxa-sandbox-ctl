#!/usr/bin/env bash
# Offline check of the pass skill's reason rules: a reason is in single quotes, in the pass's own words,
# so text from a ticket, PR or CI log never reaches a shell inside double quotes.
#   bash lib/skill-kinds.check.sh [SKILL.md]
set -u
f="${1:-$(cd "$(dirname "$0")/.." && pwd)/skills/fxa-ai-fixme/SKILL.md}"; fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
check "no reason placeholder in double quotes" "0" "$(grep -c '"<reason>"' "$f")"
check "the skill says to write each reason in its own words, in single quotes" "1" "$(tr '\n' ' ' < "$f" | grep -c 'Write each reason in your own words, in single quotes')"
exit $fail
