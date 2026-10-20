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
# A secret that may not exist: NOT_FOUND, or PERMISSION_DENIED (the manager has a grant only on the secrets that exist), reads as empty;
# any other failed read (network, quota, unavailable) stops the run before a write.
# The name ends in get: vm.sh status finds the secrets by 'get fxa-'.
# The error text goes to a root-owned temp file: $C belongs to fxa, so a link planted there would aim root's write.
E="$(mktemp)"; trap 'rm -f "$E"' EXIT
opt_get() { local v; if v="$(get "$1" 2>"$E")"; then printf '%s' "$v"; elif grep -qE "NOT_FOUND|PERMISSION_DENIED" "$E"; then :
  else echo "fxa-secrets: could not read $1 ($(head -1 "$E")); no file changed" >&2; exit 1; fi; }
pem="$(need fxa-github-app-key)"; ci="$(need fxa-circleci-token)"   # one per command: only the last one's status counts
# Runners reach Claude only through the LLM proxy, which sends an API key: a setup-token is no use here.
if [ -d "$W/fxa-sandbox-ctl" ]; then k="$(need fxa-anthropic-api-key)"; cl="ANTHROPIC_API_KEY=$k"; fi
# The .env bases too, before any write: a base that cannot be read must not leave a .env of credentials only.
[ ! -d "$W/fxa-sandbox-ctl" ] || cb="$(cat "$C/ctl.env.base")"
[ ! -d "$W/fxa-agent-bot" ] || bb="$(cat "$C/bot.env.base")"
# Plain assignments, not inside || or &&: set -e does not stop a failed $(...) there.
if [ -d "$W/fxa-agent-bot" ]; then sb="$(need fxa-slack-bot-token)"; sa="$(need fxa-slack-app-token)"; fi
r="$(opt_get fxa-runlayer-agent-token)"
s="$(opt_get fxa-sentry-token)"
g="$(opt_get fxa-grafana-token)"
j="$(opt_get fxa-jira-token)"
e="$(opt_get fxa-jira-email)"
m="$(opt_get fxa-agent-memory-key)"
h="$(opt_get fxa-dashboard-hmac)"
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
# The LLM proxy needs only the API key: its own file, so it does not load the Jira login and the rest of the ctl .env.
[ ! -d "$W/fxa-sandbox-ctl" ] || put "$C/llm-proxy.env" "ANTHROPIC_API_KEY=$k
"
unset pem ci k cl sb sa
# The MCP gateway's upstream credentials, in their own file: no other service reads it.
gw="$([ -z "$r" ] || printf 'RUNLAYER_AGENT_TOKEN=%s\n' "$r"
  [ -z "$s" ] || printf 'SENTRY_ACCESS_TOKEN=%s\n' "$s"
  [ -z "$g" ] || printf 'GRAFANA_TOKEN=%s\n' "$g")"
if [ -n "$gw" ]; then put "$C/mcp-gateway.env" "$gw
"; else rm -f "$C/mcp-gateway.env"; fi
unset gw
unset r s g
# acli keeps its Jira login in its own config, so log it in from the secrets.
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
if [ -n "$m" ]; then
  mkdir -p "$H/.ssh" && printf '%s\n' "$m" > "$H/.ssh/fxa-agent-memory"
  chown fxa:fxa "$H/.ssh" "$H/.ssh/fxa-agent-memory"; chmod 700 "$H/.ssh"; chmod 600 "$H/.ssh/fxa-agent-memory"
fi
unset m
# The key the dashboard gateway signs each user with (dashboard/server.py); none means no team writes.
if [ -n "$h" ]; then put "$C/dashboard-hmac" "$h"; else rm -f "$C/dashboard-hmac"; fi
unset h
chown -R fxa:fxa "$C" "$H/.circleci"
[ -f "$W/fxa-sandbox-ctl/.env" ] && chown fxa:fxa "$W/fxa-sandbox-ctl/.env"
[ -f "$W/fxa-agent-bot/.env" ] && chown fxa:fxa "$W/fxa-agent-bot/.env"
echo "fxa-secrets: wrote the key files and the .env files"
