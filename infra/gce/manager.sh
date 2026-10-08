#!/bin/bash
# Provision the manager VM from the laptop. Safe to run again.
#   bash infra/gce/manager.sh [project] [zone]
#   bash infra/gce/manager.sh sync [project] [zone]   pull both repos on the VM
#     after a push from the laptop; restarts only the services already running.
#   bash infra/gce/manager.sh oauth [project] [zone]  sign the MCP gateway in to
#     Runlayer in your browser; the refresh token goes straight to the VM.
# Sends your Claude setup (CLAUDE.md, settings, hooks, skills) and the .env
# files without their secrets, then runs manager-setup.sh on the VM as root.
# The secrets come from Secret Manager on the VM (fxa-secrets.service).
set -euo pipefail
MODE=provision; case "${1:-}" in sync|oauth) MODE="$1"; shift ;; esac
P="${1:-moz-fx-dev-vbudhram-sandbox}" Z="${2:-us-central1-b}" VM=fxa-manager
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BOT="${ROOT}/../fxa-agent-bot"
ssh_vm() { gcloud compute ssh "$VM" --tunnel-through-iap --zone "$Z" --project "$P" --quiet --command "$1"; }

if [ "$MODE" = oauth ]; then
  # The refresh token stays in this variable and goes straight to the VM.
  j="$(python3 "$ROOT/infra/mcp-gateway/oauth-login.py")"
  [ -n "$j" ] || { echo "ERROR: no sign-in result; the VM keeps its old token." >&2; exit 1; }
  printf '%s' "$j" | ssh_vm 'sudo install -D -m 600 -o fxa -g fxa /dev/stdin /home/fxa/.config/fxa/mcp-gateway-oauth.json && sudo systemctl restart fxa-mcp-gateway.service'
  echo "gateway signed in; the VM renews its access token from now on"
  exit 0
fi

if [ "$MODE" = sync ]; then
  # Fast-forward only: a checkout edited on the VM stops the sync instead of
  # being overwritten. The bot and the dashboard load the code at start.
  ssh_vm 'sudo -u fxa -H bash -c '"'"'
    set -e
    for r in fxa-sandbox-ctl fxa-agent-bot; do
      d=~/Desktop/working2/$r
      if [ -n "$(git -C "$d" status --porcelain --untracked-files=no)" ]; then echo "$r: local edits on the VM; not pulled"; continue; fi
      git -C "$d" pull -q --ff-only && echo "$r: $(git -C "$d" log --oneline -1)"
    done
    (cd ~/Desktop/working2/fxa-agent-bot && npm ci --silent --omit=dev)
    for s in ~/Desktop/working2/fxa-sandbox-ctl/skills/*/; do ln -sfn "${s%/}" ~/.claude/skills/"$(basename "$s")"; done
  '"'"'
  # A changed fxa-secrets: install it as root only when it is not empty and parses, then
  # run it once, before the restarts below read the .env files it writes.
  f=/home/fxa/Desktop/working2/fxa-sandbox-ctl/infra/gce/fxa-secrets.sh
  if sudo test -s $f && sudo bash -n $f && ! sudo cmp -s $f /usr/local/sbin/fxa-secrets; then
    sudo install -m 700 -o root -g root $f /usr/local/sbin/fxa-secrets && echo "installed fxa-secrets" && sudo /usr/local/sbin/fxa-secrets | tail -1
  fi
  for u in fxa-agent-bot fxa-dashboard; do systemctl is-active -q $u && sudo systemctl restart $u && echo "restarted $u"; done; true'
  exit 0
fi

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# Your Claude setup. Skills that link into this repo are linked again on the
# VM, from its own clone; everything else is copied.
(cd ~/.claude && COPYFILE_DISABLE=1 tar --no-xattrs -czf "$tmp/claude.tgz" \
  CLAUDE.md settings.json hooks $(find skills -mindepth 1 -maxdepth 1 -type d ! -type l))

# The .env files without their secrets. The VM drops the laptop-only lines:
# impersonation (it runs as the service account) and the key path.
grep -vE '^(CLAUDE_CODE_OAUTH_TOKEN|FXA_GCE_SERVICE_ACCOUNT|GITHUB_APP_PEM|FXA_GCE_SSH_DIRECT)=' "${ROOT}/.env" | grep -E '^[A-Z_]+=' > "$tmp/ctl.env.base"
{ echo "GITHUB_APP_PEM=/home/fxa/.config/fxa/github-app.pem"
  echo "FXA_GCE_SSH_DIRECT=1"
  # e2-standard-4 plus its 200 GB balanced disk, list price: the dashboard's always-on cost.
  echo "FXA_MANAGER_HOURLY_USD=0.16"
  # Runners reach Claude through the proxy on this VM, never with the key,
  # and MCP tools through the gateway beside it.
  ip="$(gcloud compute instances describe "$VM" --project "$P" --zone "$Z" --format 'value(networkInterfaces[0].networkIP)')"
  echo "FXA_LLM_PROXY_URL=http://${ip}:8788"
  echo "FXA_MCP_GATEWAY_URL=http://${ip}:8789"; } >> "$tmp/ctl.env.base"
# After the cutover the laptop's bot .env is renamed .env.retired, so no second
# bot can start there; it is still the source of these settings.
BOT_ENV="${BOT}/.env"; [ -f "$BOT_ENV" ] || BOT_ENV="${BOT}/.env.retired"
grep -vE '^(SLACK_BOT_TOKEN|SLACK_APP_TOKEN)=' "$BOT_ENV" | grep -E '^[A-Z_]+=' > "$tmp/bot.env.base"
# A secret must never reach these files; stop if one looks like it did.
if grep -qE 'xox[abpr]-|xapp-|ghp_|github_pat_|sk-ant-|PRIVATE KEY' "$tmp/ctl.env.base" "$tmp/bot.env.base"; then
  echo "ERROR: a secret-looking value is in the .env base files; not sending them." >&2; exit 1
fi

# mzcld, the yardstick IAP proxy, is in a private repo the VM cannot fetch: build the
# pinned tag here, with gh's login (go's own fetch has none).
if gh repo clone mozilla/mozcloud "$tmp/mozcloud" -- -q --depth 1 --branch tools/mzcld/v0.3.1 >&2 2>/dev/null \
   && (cd "$tmp/mozcloud/tools/mzcld" && GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o "$tmp/mzcld" . >&2); then :
else echo "WARN: could not build mzcld; the grafana connector cannot reach yardstick" >&2; fi

for f in claude.tgz ctl.env.base bot.env.base mzcld; do
  [ -f "$tmp/$f" ] || continue
  dest=/tmp/fxa-$f; [ "$f" = claude.tgz ] && dest=/tmp/fxa-claude-bundle.tgz
  ssh_vm "umask 077; cat > $dest" < "$tmp/$f"
done
# fxa-secrets lives in its own file; setup gets it spliced in at its marker line.
{ grep -m1 '^CLAUDE_CODE_VERSION=' "${ROOT}/packer/scripts/04-claude.sh"
  sed -e "/^__FXA_SECRETS__\$/{r ${ROOT}/infra/gce/fxa-secrets.sh" -e 'd;}' "${ROOT}/infra/gce/manager-setup.sh"; } | ssh_vm 'sudo bash -s'
# The MCP gateway's connectors, when you keep them locally. Credentials stay
# ${VAR} references filled from Secret Manager, so a literal one stops here.
G="${HOME}/.config/fxa/mcp-gateway.json"
if [ -f "$G" ]; then
  jq -e . "$G" >/dev/null || { echo "ERROR: $G is not valid JSON." >&2; exit 1; }
  if grep -qE 'Bearer [^$"]|xox[abpr]-|ghp_|github_pat_|sk-ant-|sntry[a-z]_|glsa_' "$G"; then
    echo "ERROR: $G holds a literal credential; use \${VAR} and Secret Manager." >&2; exit 1
  fi
  ssh_vm 'sudo install -D -m 600 -o fxa -g fxa /dev/stdin /home/fxa/.config/fxa/mcp-gateway.json && sudo systemctl restart fxa-mcp-gateway.service' < "$G"
fi
# reporters.tsv maps Jira reporters to GitHub logins for PR assignees. It holds
# emails, so the GCS state mirror leaves it out: send it straight to the VM when
# the VM has none.
R="${HOME}/.claude/state/fxa-ai-fixme/reporters.tsv"
if [ -f "$R" ] && ! ssh_vm 'sudo test -f /home/fxa/.claude/state/fxa-ai-fixme/reporters.tsv'; then
  ssh_vm 'sudo install -D -m 600 -o fxa -g fxa /dev/stdin /home/fxa/.claude/state/fxa-ai-fixme/reporters.tsv' < "$R"
fi
