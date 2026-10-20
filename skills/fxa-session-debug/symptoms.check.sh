#!/usr/bin/env bash
# Offline check that each bot or controller message the symptom table quotes is still in the code, so an
# operator who searches a thread's text finds its row. FXA_BOT_REPO: the bot tree (default ../fxa-agent-bot).
#   bash skills/fxa-session-debug/symptoms.check.sh
set -u
here="$(cd "$(dirname "$0")" && pwd)"; root="$here/../.."; bot="${FXA_BOT_REPO:-$root/../fxa-agent-bot}"
[ -d "$bot/src" ] || { echo "skip: no bot tree at $bot"; exit 0; }
fail=0
for t in "Paused: nobody replied for a while" "I paused: this session reached its usage limit" "handoff file not found" \
  "waiting for handoff file" "Agent sessions are paused right now" "nothing to push: no files changed" "set ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN"; do
  grep -qF -- "\`$t" "$here/SKILL.md" || { echo "FAIL the table no longer quotes: $t"; fail=1; continue; }
  if grep -rqF -- "$t" "$bot/src" "$root/lib" "$root/fxa-sandbox-ctl"; then echo "ok   in the code: $t"; else echo "FAIL the code no longer says: $t"; fail=1; fi
done
[ "$fail" = 0 ] && echo "all checks pass"
exit "$fail"
