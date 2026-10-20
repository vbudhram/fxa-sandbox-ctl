#!/usr/bin/env bash
# env-drift.sh <.env> <base>   The setting names whose line in .env is missing from base or differs from it:
# a hand edit there is lost at the next fxa-secrets run. Prints names only, never a value. The Slack tokens
# come from Secret Manager, not the base, so they are left out.
set -u
[ -r "$1" ] && [ -r "$2" ] || exit 0
grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$1" | grep -vE '^SLACK_(BOT|APP)_TOKEN=' | while IFS= read -r line; do
  grep -qxF -- "$line" "$2" || printf '%s\n' "${line%%=*}"
done
