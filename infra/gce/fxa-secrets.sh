#!/bin/bash
set -euo pipefail
H=/home/fxa W=/home/fxa/Desktop/working2 C=/home/fxa/.config/fxa
P="$(curl -fsS -H Metadata-Flavor:Google http://metadata.google.internal/computeMetadata/v1/project/project-id)"
get() { gcloud secrets versions access latest --secret "$1" --project "$P" 2>/dev/null; }
umask 077
get fxa-github-app-key > "$C/github-app.pem"
mkdir -p "$H/.circleci"; printf 'token: %s\n' "$(get fxa-circleci-token)" > "$H/.circleci/cli.yml"
if [ -d "$W/fxa-sandbox-ctl" ]; then
  { cat "$C/ctl.env.base"
    # The API key when there is one (billed per token), else a setup-token.
    k="$(get fxa-anthropic-api-key || true)"; t="$(get fxa-claude-token || true)"
    if [ -n "$k" ]; then printf 'ANTHROPIC_API_KEY=%s\n' "$k"; elif [ -n "$t" ]; then printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$t"; fi
    true; } > "$W/fxa-sandbox-ctl/.env"
fi
if [ -d "$W/fxa-agent-bot" ]; then
  { cat "$C/bot.env.base"
    printf 'SLACK_BOT_TOKEN=%s\n' "$(get fxa-slack-bot-token)"
    printf 'SLACK_APP_TOKEN=%s\n' "$(get fxa-slack-app-token)"; } > "$W/fxa-agent-bot/.env"
fi
# The MCP gateway's upstream credential, in its own file: no other service reads it.
r="$(get fxa-runlayer-agent-token || true)"
if [ -n "$r" ]; then printf 'RUNLAYER_AGENT_TOKEN=%s\n' "$r" > "$C/mcp-gateway.env"; else rm -f "$C/mcp-gateway.env"; fi
unset r
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
chown -R fxa:fxa "$C" "$H/.circleci"
[ -f "$W/fxa-sandbox-ctl/.env" ] && chown fxa:fxa "$W/fxa-sandbox-ctl/.env"
[ -f "$W/fxa-agent-bot/.env" ] && chown fxa:fxa "$W/fxa-agent-bot/.env"
echo "fxa-secrets: wrote the key files and the .env files"
