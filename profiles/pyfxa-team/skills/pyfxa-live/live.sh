#!/usr/bin/env bash
# live.sh [pytest args...]   PyFxA's live tests against the local FxA. See SKILL.md.
set -uo pipefail
auth="http://localhost:9000"
if ! curl -sf "${auth}/__heartbeat__" >/dev/null 2>&1; then
  echo "pyfxa-live: starting FxA (fxa-start)..."
  ( cd "${FXA_DIR:-/home/agent/fxa}" && source /etc/agent-env.sh && fxa-start ) >/tmp/pyfxa-live-start.log 2>&1 \
    || { echo "pyfxa-live: fxa-start failed; see /tmp/pyfxa-live-start.log" >&2; exit 2; }
  curl -sf "${auth}/__heartbeat__" >/dev/null || { echo "pyfxa-live: the auth server does not answer on :9000" >&2; exit 2; }
fi
bash ~/.claude/skills/pyfxa-verify/verify.sh --setup || exit 2
v="${PYFXA_VENV:-/home/agent/.pyfxa-venv}"
cd "${PYFXA_DIR:-/home/agent/pyfxa}" || exit 2
out="$(FXA_RUN_LIVE_TESTS=1 FXA_TEST_SERVER_URL="${auth}/v1" FXA_TEST_MAIL_URL="http://127.0.0.1:9001" \
  "$v/bin/python" -m pytest -q "${@:-fxa/tests/test_core.py}" 2>&1)"; rc=$?
printf '%s\n' "$out" | tail -30
if [ "$rc" != 0 ] && grep -q 'stage.mozaws.net\|restmail.net' <<< "$out"; then
  echo "pyfxa-live: the tests still call stage or restmail.net. Make them read FXA_TEST_SERVER_URL and FXA_TEST_MAIL_URL first." >&2
fi
exit "$rc"
