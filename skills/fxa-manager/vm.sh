#!/bin/bash
# Operate the fxa-manager VM, from the laptop or on the VM itself.
#   vm.sh status          services, timers, pipeline, repos, disk, secrets, runners
#   vm.sh run '<cmd>'     run a shell command as fxa in the controller repo
#   vm.sh sys '<cmd>'     run as your own login user, who can sudo (systemctl, journalctl)
#   vm.sh screen          read the tmux session "main" (read-only, secrets masked)
#   vm.sh sync            pull both repos on the VM (after a push from the laptop)
#   vm.sh ssh             print the ssh command for a person
# Never prints a secret value: secrets show as present or missing.
set -euo pipefail
P="${FXA_GCE_PROJECT:-moz-fx-dev-vbudhram-sandbox}" Z="${FXA_MANAGER_ZONE:-us-central1-b}" VM=fxa-manager
HERE="$(cd "$(dirname "$0")" && pwd)"
CTL_ROOT="$(cd "$HERE/../.." && pwd)"
mask() { sed -E 's/(sk-ant-[a-z0-9]+-)[A-Za-z0-9_-]+/\1<masked>/g; s/(xox[abpr]-|xapp-|ghs_|ghp_|github_pat_)[A-Za-z0-9_-]+/\1<masked>/g'; }

# On the VM, run here; on the laptop, run over IAP ssh.
on_vm() {
  if [ "$(hostname -s)" = "$VM" ]; then bash -s
  else gcloud compute ssh "$VM" --tunnel-through-iap --zone "$Z" --project "$P" --quiet --command 'bash -s' 2>/dev/null
  fi
}

case "${1:-status}" in
  status)
    on_vm <<'EOF' | mask
echo "== services"
for u in fxa-secrets fxa-agent-bot fxa-dashboard; do printf '  %-16s %s\n' "$u" "$(systemctl is-active $u 2>/dev/null)"; done
for t in fxa-pass fxa-triage; do printf '  %-16s timer %s\n' "$t" "$(systemctl is-active $t.timer 2>/dev/null)"; done
sudo -u fxa -H bash -c '
cd ~/Desktop/working2/fxa-sandbox-ctl || exit 0
echo "== pipeline"; echo "  paused: $(./fxa-sandbox-ctl paused 2>/dev/null || echo no)"
echo "== repos"
for r in fxa-sandbox-ctl fxa-agent-bot; do d=~/Desktop/working2/$r; git -C "$d" fetch -q origin 2>/dev/null
  printf "  %-16s %s  (%s behind origin)\n" "$r" "$(git -C "$d" log --oneline -1 | cut -c1-60)" "$(git -C "$d" rev-list --count HEAD..origin/main 2>/dev/null)"; done
echo "== claude credential for runners"
grep -q "^ANTHROPIC_API_KEY=" .env && echo "  ANTHROPIC_API_KEY: present" || { grep -q "^CLAUDE_CODE_OAUTH_TOKEN=" .env && echo "  setup-token: present" || echo "  MISSING: runners cannot start"; }
echo "== tmux"; tmux ls 2>/dev/null | sed "s/^/  /" || echo "  no session"
echo "== open errors"; ./fxa-sandbox-ctl errors 2>/dev/null | grep -cE "^[0-9a-f]{10}" | sed "s/^/  /"
'
echo "== disk"; df -h / | tail -1 | awk '{print "  " $4 " free of " $2}'
echo "== runners"; gcloud compute instances list --filter='name~^agent-' --format='value(name,status)' 2>/dev/null | sed 's/^/  /'
echo "== secrets the VM can read (present or missing, never the value)"
for s in fxa-slack-bot-token fxa-slack-app-token fxa-github-app-key fxa-circleci-token fxa-anthropic-api-key fxa-jira-token; do
  gcloud secrets versions access latest --secret "$s" >/dev/null 2>&1 && printf '  %-22s present\n' "$s" || printf '  %-22s missing\n' "$s"
done
EOF
    ;;
  run)
    [ -n "${2:-}" ] || { echo "usage: vm.sh run '<command>'" >&2; exit 1; }
    printf 'sudo -u fxa -H bash -lc %q\n' "cd ~/Desktop/working2/fxa-sandbox-ctl && $2" | on_vm | mask ;;
  sys)
    [ -n "${2:-}" ] || { echo "usage: vm.sh sys '<command>'" >&2; exit 1; }
    printf '%s\n' "$2" | on_vm | mask ;;
  screen)
    echo 'sudo -u fxa -H tmux capture-pane -p -t main -S -40 | sed "/^\s*$/d" | tail -40' | on_vm | mask ;;
  sync)
    bash "$CTL_ROOT/infra/gce/manager.sh" sync "$P" "$Z" ;;
  ssh)
    echo "gcloud compute ssh $VM --tunnel-through-iap --zone $Z --project $P -- -L 8787:localhost:8787"
    echo "then: sudo -iu fxa; tmux new -As main" ;;
  *) sed -n '2,9p' "$0"; exit 1 ;;
esac
