#!/usr/bin/env bash
# Offline check for env-drift.sh: a hand edit in the bot .env that the base lacks is named, never its value.
#   bash skills/fxa-manager/env-drift.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT; here="$(cd "$(dirname "$0")" && pwd)"
printf 'A=1\nALLOWED_CHANNELS=C1\n' > "$tmp/base"
printf 'A=1\nALLOWED_CHANNELS=C1,C2\nNEW_ONE=x\nSLACK_BOT_TOKEN=xoxb-test\n# a comment\n' > "$tmp/env"
out="$(bash "$here/env-drift.sh" "$tmp/env" "$tmp/base")"
check "a changed and a new setting are named; same lines, tokens and comments are not" "ALLOWED_CHANNELS NEW_ONE" "$(echo $out)"
check "no value is printed" "0" "$(grep -c 'C2\|x$\|xoxb' <<< "$out")"
check "a missing file prints nothing and exits 0" "0|" "$(bash "$here/env-drift.sh" "$tmp/none" "$tmp/base"; echo "$?|$(bash "$here/env-drift.sh" "$tmp/none" "$tmp/base")")"
check "vm.sh status runs it" "yes" "$(grep -q 'env-drift.sh ../fxa-agent-bot/.env ~/.config/fxa/bot.env.base' "$here/vm.sh" && echo yes)"
printf 'FXA_X=1\n' > "$tmp/cbase"; printf 'FXA_X=2\nANTHROPIC_API_KEY=k\nPIPE_JIRA_BASIC=a:b\n' > "$tmp/cenv"
check "the ctl .env: a hand edit is named; the secrets fxa-secrets adds are skipped" "FXA_X" "$(bash "$here/env-drift.sh" "$tmp/cenv" "$tmp/cbase" 'ANTHROPIC_API_KEY|CLAUDE_CODE_OAUTH_TOKEN|PIPE_JIRA_BASIC' | paste -sd' ' -)"
check "vm.sh status also runs it on the ctl .env" "yes" "$(grep -q 'env-drift.sh .env ~/.config/fxa/ctl.env.base' "$here/vm.sh" && echo yes)"
[ "$fail" = 0 ] && echo "all checks pass"
exit "$fail"
