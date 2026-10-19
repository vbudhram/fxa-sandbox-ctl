#!/bin/bash
# infra/gce/firewall.sh — give each ingress rule of the runner network a target, so a port
# opens only on the VMs that use it. plan prints the gcloud writes; apply runs them.
#   bash infra/gce/firewall.sh plan|apply
# Run apply only after the manager runs a vm_clone that tags runners: a runner made
# without the tag gets no ssh from the manager. allow-iap-ssh keeps no target: IAP
# checks IAM for each tunnel, and the laptop reaches every VM through it.
set -euo pipefail
: "${FXA_GCE_PROJECT:?set FXA_GCE_PROJECT}"
NET="${FXA_GCE_NETWORK:-fxa-sandbox}"
FC="${FXA_FC_INSTANCE:-fxa-fc-spike}"
SA="fxa-ai-fixme-manager@${FXA_GCE_PROJECT}.iam.gserviceaccount.com"
TAG=fxa-runner
mode="${1:-plan}"
case "$mode" in plan|apply) ;; *) echo "usage: firewall.sh plan|apply" >&2; exit 2 ;; esac
g() { gcloud --project "$FXA_GCE_PROJECT" --quiet "$@"; }
w() { if [ "$mode" = apply ]; then g "$@"; else echo "would run: gcloud $*"; fi; }

# The tag goes on first, so the manager keeps ssh to the runners, the answer VM and the Firecracker host.
while read -r name zone tags; do
  [ -n "$name" ] || continue
  [[ ",${tags}," == *",${TAG},"* ]] || w compute instances add-tags "$name" --zone "$zone" --tags "$TAG"
done < <(g compute instances list --filter="labels.fxa-agent:* OR name=${FC}" --format='value(name,zone.basename(),tags.items.list())')

# rule <name> <allow> <sources> <target flag> <target>
rule() {
  if g compute firewall-rules describe "$NET-$1" >/dev/null 2>&1; then
    w compute firewall-rules update "$NET-$1" --allow "$2" --source-ranges "$3" "$4" "$5"
  else
    w compute firewall-rules create "$NET-$1" --network "$NET" --direction INGRESS --allow "$2" --source-ranges "$3" "$4" "$5"
  fi
}
rule allow-manager-ssh tcp:22 10.42.2.0/28 --target-tags "$TAG"
rule allow-desktop-gw tcp:6080 10.42.1.0/26 --target-tags "$TAG"
rule allow-runner-llm-proxy tcp:8788 10.42.0.0/24,10.42.16.0/24 --target-service-accounts "$SA"
rule allow-runner-mcp-gateway tcp:8789 10.42.0.0/24,10.42.16.0/24 --target-service-accounts "$SA"
echo "ok: $mode"
