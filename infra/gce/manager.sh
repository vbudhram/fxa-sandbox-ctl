#!/bin/bash
# Provision the manager VM from the laptop. Safe to run again.
#   bash infra/gce/manager.sh [project] [zone]
#   bash infra/gce/manager.sh sync [project] [zone]   pull both repos on the VM
#     after a push from the laptop; restarts only the services already running.
# Sends your Claude setup (CLAUDE.md, settings, hooks, skills) and the .env
# files without their secrets, then runs manager-setup.sh on the VM as root.
# The secrets come from Secret Manager on the VM (fxa-secrets.service).
set -euo pipefail
MODE=provision; [ "${1:-}" = sync ] && { MODE=sync; shift; }
P="${1:-moz-fx-dev-vbudhram-sandbox}" Z="${2:-us-central1-b}" VM=fxa-manager
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BOT="${ROOT}/../fxa-agent-bot"
ssh_vm() { gcloud compute ssh "$VM" --tunnel-through-iap --zone "$Z" --project "$P" --quiet --command "$1"; }

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
  echo "FXA_GCE_SSH_DIRECT=1"; } >> "$tmp/ctl.env.base"
# After the cutover the laptop's bot .env is renamed .env.retired, so no second
# bot can start there; it is still the source of these settings.
BOT_ENV="${BOT}/.env"; [ -f "$BOT_ENV" ] || BOT_ENV="${BOT}/.env.retired"
grep -vE '^(SLACK_BOT_TOKEN|SLACK_APP_TOKEN)=' "$BOT_ENV" | grep -E '^[A-Z_]+=' > "$tmp/bot.env.base"
# A secret must never reach these files; stop if one looks like it did.
if grep -qE 'xox[abpr]-|xapp-|ghp_|github_pat_|sk-ant-|PRIVATE KEY' "$tmp/ctl.env.base" "$tmp/bot.env.base"; then
  echo "ERROR: a secret-looking value is in the .env base files; not sending them." >&2; exit 1
fi

for f in claude.tgz ctl.env.base bot.env.base; do
  dest=/tmp/fxa-$f; [ "$f" = claude.tgz ] && dest=/tmp/fxa-claude-bundle.tgz
  ssh_vm "umask 077; cat > $dest" < "$tmp/$f"
done
ssh_vm 'sudo bash -s' < "${ROOT}/infra/gce/manager-setup.sh"
