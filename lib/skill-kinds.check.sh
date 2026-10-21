#!/usr/bin/env bash
# Offline check of the pass skill's reason rules: a reason is in single quotes, in the pass's own words,
# so text from a ticket, PR or CI log never reaches a shell inside double quotes; and the skill names
# every blocked and skip kind that the code takes.
#   bash lib/skill-kinds.check.sh [skill file] [pipeline.sh]   (default: SKILL.md and the parts beside it)
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
s="$root/skills/fxa-ai-fixme"; f="$(mktemp)"; trap 'rm -f "$f"' EXIT
if [ -n "${1:-}" ]; then cat "$1" > "$f"; else cat "$s/SKILL.md" "$s/launch.md" "$s/admission.md" "$s/feedback.md" > "$f"; fi
code="${2:-$root/lib/pipeline.sh}"; fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
check "no reason placeholder in double quotes" "0" "$(grep -c '"<reason>"' "$f")"
flat="$(tr '\n' ' ' < "$f")"
check "the skill says to write each reason in its own words, in single quotes" "1" "$(grep -c 'Write each reason in your own words, in single quotes' <<< "$flat")"
check "the skill keeps kind operator to the operator's own prompt" "1" "$(grep -c "Use operator only when the operator asks in this session's own prompt" <<< "$flat")"
# Each example reason is one the shell can take inside single quotes: no apostrophe in it.
check "no example reason has a single quote in it" "0" "$(grep -oE "for example '[^']*'[a-z]" "$f" | wc -l | tr -d ' ')"
check "the decline rule asks for single quotes and no single quote" "1" "$(grep -c 'in single quotes, with no single quote in it and no text copied from the PR' <<< "$flat")"
kinds="$(sed -n 's/^_PIPE_BLOCKED_KINDS="\(.*\)"$/\1/p; s/^_PIPE_SKIP_KINDS="\(.*\)"$/\1/p' "$code")"
check "the code has kind lists" "yes" "$([ -n "$kinds" ] && echo yes || echo no)"
for k in $kinds; do check "the skill names the kind $k" "yes" "$(grep -qw -- "$k" <<< "$flat" && echo yes || echo no)"; done
exit $fail
