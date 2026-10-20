#!/bin/bash
set -euo pipefail
H=/home/fxa W=/home/fxa/Desktop/working2 C=/home/fxa/.config/fxa
P="$(curl -fsS -H Metadata-Flavor:Google http://metadata.google.internal/computeMetadata/v1/project/project-id)"
get() { gcloud secrets versions access latest --secret "$1" --project "$P"; }
# The credentials the services cannot start without: all of them read, or no file changes, so a failed
# read (IAM, quota, network not ready) keeps the last good files and the units on them.
need() { local v; v="$(get "$1")" && [ -n "$v" ] || { echo "fxa-secrets: could not read $1; no file changed" >&2; exit 1; }; printf '%s' "$v"; }
put() { printf '%s' "$2" > "$1.new" && mv "$1.new" "$1"; }
umask 077
pem="$(need fxa-github-app-key)"; ci="$(need fxa-circleci-token)"   # one per command: only the last one's status counts
if [ -d "$W/fxa-sandbox-ctl" ]; then
  # The API key when there is one (billed per token), else a setup-token.
  k="$(get fxa-anthropic-api-key || true)"; t="$(get fxa-claude-token || true)"
  if [ -n "$k" ]; then cl="ANTHROPIC_API_KEY=$k"; elif [ -n "$t" ]; then cl="CLAUDE_CODE_OAUTH_TOKEN=$t"
  else echo "fxa-secrets: could not read fxa-anthropic-api-key or fxa-claude-token; no file changed" >&2; exit 1; fi
fi
# The .env bases too, before any write: a base that cannot be read must not leave a .env of credentials only.
[ ! -d "$W/fxa-sandbox-ctl" ] || cb="$(cat "$C/ctl.env.base")"
[ ! -d "$W/fxa-agent-bot" ] || bb="$(cat "$C/bot.env.base")"
# Plain assignments, not inside || or &&: set -e does not stop a failed $(...) there.
if [ -d "$W/fxa-agent-bot" ]; then sb="$(need fxa-slack-bot-token)"; sa="$(need fxa-slack-app-token)"; fi
put "$C/github-app.pem" "$pem
"
mkdir -p "$H/.circleci"; put "$H/.circleci/cli.yml" "token: $ci
"
[ ! -d "$W/fxa-sandbox-ctl" ] || put "$W/fxa-sandbox-ctl/.env" "$cb
$cl
"
[ ! -d "$W/fxa-agent-bot" ] || put "$W/fxa-agent-bot/.env" "$bb
SLACK_BOT_TOKEN=$sb
SLACK_APP_TOKEN=$sa
"
unset pem ci k t cl sb sa
# The MCP gateway's upstream credentials, in their own file: no other service reads it.
r="$(get fxa-runlayer-agent-token || true)" s="$(get fxa-sentry-token || true)" g="$(get fxa-grafana-token || true)"
{ [ -z "$r" ] || printf 'RUNLAYER_AGENT_TOKEN=%s\n' "$r"
  [ -z "$s" ] || printf 'SENTRY_ACCESS_TOKEN=%s\n' "$s"
  [ -z "$g" ] || printf 'GRAFANA_TOKEN=%s\n' "$g"; } > "$C/mcp-gateway.env"
[ -s "$C/mcp-gateway.env" ] || rm -f "$C/mcp-gateway.env"
unset r s g
# acli keeps its Jira login in its own config, so log it in from the secrets.
j="$(get fxa-jira-token || true)" e="$(get fxa-jira-email || true)"
if [ -z "$j" ] || [ -z "$e" ]; then
  echo "fxa-secrets: no fxa-jira-token or fxa-jira-email, so acli keeps its old Jira login" >&2
elif command -v acli >/dev/null; then
  # The pipe must start inside fxa's shell: through sudo's own terminal, acli reads no token.
  T="$j" E="$e" sudo -u fxa -H --preserve-env=T,E bash -c \
    'printf "%s\n" "$T" | acli jira auth login --site mozilla-hub.atlassian.net --email "$E" --token' >/dev/null 2>&1 \
    || echo "fxa-secrets: the acli Jira login failed" >&2
fi
# The same account puts merged tickets in the sprint: acli cannot write the Sprint field,
# so the controller calls Jira's REST API with these (jira_sprint_add).
[ -n "$j" ] && [ -n "$e" ] && [ -f "$W/fxa-sandbox-ctl/.env" ] && printf 'PIPE_JIRA_BASIC=%s:%s\n' "$e" "$j" >> "$W/fxa-sandbox-ctl/.env"
unset j e
# The team memory repo's deploy key (lib/memory.sh), when the secret exists; a rebuilt manager keeps writing.
m="$(get fxa-agent-memory-key || true)"
if [ -n "$m" ]; then
  mkdir -p "$H/.ssh" && printf '%s\n' "$m" > "$H/.ssh/fxa-agent-memory"
  chown fxa:fxa "$H/.ssh" "$H/.ssh/fxa-agent-memory"; chmod 700 "$H/.ssh"; chmod 600 "$H/.ssh/fxa-agent-memory"
fi
unset m
# The key the dashboard gateway signs each user with (dashboard/server.py); none means no team writes.
h="$(get fxa-dashboard-hmac || true)"
if [ -n "$h" ]; then printf '%s' "$h" > "$C/dashboard-hmac"; else rm -f "$C/dashboard-hmac"; fi
unset h
chown -R fxa:fxa "$C" "$H/.circleci"
[ -f "$W/fxa-sandbox-ctl/.env" ] && chown fxa:fxa "$W/fxa-sandbox-ctl/.env"
[ -f "$W/fxa-agent-bot/.env" ] && chown fxa:fxa "$W/fxa-agent-bot/.env"
echo "fxa-secrets: wrote the key files and the .env files"
