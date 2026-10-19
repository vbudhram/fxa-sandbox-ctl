#!/usr/bin/env bash
# Offline check for infra/gce/firewall.sh, with a fake gcloud: plan writes nothing, apply tags the
# untagged VMs before any rule changes, and every rule gets a target.
#   bash infra/gce/firewall.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
here="$(cd "$(dirname "$0")" && pwd -P)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gcloud" <<G
#!/bin/bash
echo "\$*" >> "$tmp/calls"
case "\$*" in
  *"instances list"*) printf 'agent-a1\tz-a\t\nfxa-answer\tz-b\tother\nfxa-fc-spike\tz-a\tfxa-runner\n' ;;
  *"firewall-rules describe fxa-sandbox-allow-runner-mcp-gateway"*) exit 1 ;;
esac
G
chmod +x "$tmp/bin/gcloud"
fw() { PATH="$tmp/bin:$PATH" FXA_GCE_PROJECT=p1 bash "$here/firewall.sh" "$@" 2>&1; }
out="$(fw plan)"
check "plan calls only list and describe" "0" "$(grep -cE 'add-tags|rules (update|create)' "$tmp/calls")"
check "plan names the writes" "2|4" "$(grep -c 'would run: gcloud compute instances add-tags' <<< "$out")|$(grep -cE 'would run: gcloud compute firewall-rules (update|create)' <<< "$out")"
: > "$tmp/calls"; fw apply >/dev/null
check "apply tags the two untagged VMs, not the tagged host" "agent-a1 fxa-answer" "$(grep 'add-tags' "$tmp/calls" | awk '{print $7}' | paste -sd' ' -)"
check "the tags go on before any rule changes" "true" "$([ "$(grep -n 'add-tags' "$tmp/calls" | tail -1 | cut -d: -f1)" -lt "$(grep -nE 'rules (update|create)' "$tmp/calls" | head -1 | cut -d: -f1)" ] && echo true)"
check "ssh and the desktop port go to the runner tag only" "1|1" \
  "$(grep -c 'rules update fxa-sandbox-allow-manager-ssh --allow tcp:22 --source-ranges 10.42.2.0/28 --target-tags fxa-runner' "$tmp/calls")|$(grep -c 'rules update fxa-sandbox-allow-desktop-gw --allow tcp:6080 --source-ranges 10.42.1.0/26 --target-tags fxa-runner' "$tmp/calls")"
check "8788 and 8789 go to the manager only; a missing rule is created" "1|1" \
  "$(grep -c 'rules update fxa-sandbox-allow-runner-llm-proxy --allow tcp:8788 .*--target-service-accounts fxa-ai-fixme-manager@p1' "$tmp/calls")|$(grep -c 'rules create fxa-sandbox-allow-runner-mcp-gateway --network fxa-sandbox --direction INGRESS --allow tcp:8789 .*--target-service-accounts fxa-ai-fixme-manager@p1' "$tmp/calls")"
check "no rule is left without a target" "0" "$(grep -E 'rules (update|create)' "$tmp/calls" | grep -cvE -- '--target-(tags|service-accounts) ')"
check "a bad mode is refused and calls nothing" "2|0" "$( : > "$tmp/calls"; fw nope >/dev/null; echo $?)|$(grep -c . "$tmp/calls")"
exit "$fail"
