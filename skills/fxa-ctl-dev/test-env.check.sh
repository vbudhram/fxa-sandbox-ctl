#!/usr/bin/env bash
# Offline check: test.sh keeps the checks off the repo .env and the real team records, as CI has neither.
#   bash skills/fxa-ctl-dev/test-env.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
here="$(cd "$(dirname "$0")" && pwd)"; root="$here/../.."; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
loader="$(sed -n '/^# Load KEY=VALUE lines from .env/,/^fi$/p' "$root/fxa-sandbox-ctl")"
echo 'FXA_ENV_PROBE=from-dotenv' > "$tmp/.env"
check "the entry point loads the .env" "from-dotenv" "$(env -u FXA_NO_DOTENV SCRIPT_DIR="$tmp" bash -c "$loader"'; echo "${FXA_ENV_PROBE:-}"')"
check "FXA_NO_DOTENV=1 skips the .env" "" "$(FXA_NO_DOTENV=1 SCRIPT_DIR="$tmp" bash -c "$loader"'; echo "${FXA_ENV_PROBE:-}"')"
check "test.sh sets FXA_NO_DOTENV" "1" "$(grep -c '^export FXA_NO_DOTENV=1' "$here/test.sh")"
check "test.sh points FXA_TEAMS_DIR at an empty temp path" "1" "$(grep -c '^export FXA_TEAMS_DIR="${TMPDIR:-/tmp}/fxa-test-no-teams-' "$here/test.sh")"
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
