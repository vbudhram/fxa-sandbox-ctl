#!/usr/bin/env bash
# Offline check for infra/gce/gateway.sh, with a fake gcloud: deploy sets the network, the secret and
# the derived values, keeps what .env does not name, and makes the firewall rule only when it is missing.
#   bash infra/gce/gateway.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
here="$(cd "$(dirname "$0")" && pwd -P)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/repo/infra/gce" "$tmp/bin"; cp "$here/gateway.sh" "$tmp/repo/infra/gce/"
cat > "$tmp/bin/gcloud" <<G
#!/bin/bash
echo "\$*" >> "$tmp/calls"
case "\$*" in
  *"instances describe fxa-manager"*) echo 10.42.2.9 ;;
  *"subnets describe"*) echo 10.42.1.0/26 ;;
  *"firewall-rules describe"*) [ -f "$tmp/rule" ] ;;
  *"run services describe"*) echo '{"spec":{"template":{"spec":{"containers":[{"env":[{"name":"MANAGER_URL","value":"http://10.42.2.2:8787"},{"name":"DASHBOARD_USERS","value":"a@example.com"}]}]}}}}' ;;
esac
G
chmod +x "$tmp/bin/gcloud"
gw() { ( cd "$tmp/repo" && PATH="$tmp/bin:$PATH" env -u FXA_DASHBOARD_USERS -u FXA_GATEWAY_IAP_AUDIENCE FXA_GCE_PROJECT=p1 "$@" bash infra/gce/gateway.sh "${ARGS[@]}" 2>&1 ); }
ARGS=(plan); out="$(gw)"
check "plan says what deploy changes, and no email" "1|0" "$(grep -c 'MANAGER_URL: changes (http://10.42.2.2:8787 -> http://10.42.2.9:8787)' <<< "$out")|$(grep -c '@example.com' <<< "$out")"
check "plan changes nothing" "0" "$(grep -cE 'run deploy|services update|rules create' "$tmp/calls")"
: > "$tmp/calls"; ARGS=(deploy); gw >/dev/null
d="$(grep 'run deploy' "$tmp/calls")"
check "deploy keeps the network, the account, one instance and the secret" "1|1|1|1|1" \
  "$(grep -c -- '--network fxa-sandbox --subnet fxa-desktop-gw --vpc-egress private-ranges-only' <<< "$d")|$(grep -c -- '--service-account fxa-desktop-gw@p1.iam.gserviceaccount.com' <<< "$d")|$(grep -c -- '--max-instances 1' <<< "$d")|$(grep -c -- '--update-secrets DASHBOARD_HMAC=fxa-dashboard-hmac:latest' <<< "$d")|$(grep -c -- '--no-allow-unauthenticated' <<< "$d")"
check "with no users in .env, deploy leaves DASHBOARD_USERS and IAP_AUDIENCE as they are" "0|0|1" \
  "$(grep -c 'DASHBOARD_USERS=' <<< "$d")|$(grep -c 'IAP_AUDIENCE=' <<< "$d")|$(grep -c 'DESKTOP_BUCKET=p1-fxa-ai-fixme;MANAGER_URL=http://10.42.2.9:8787' <<< "$d")"
check "a missing firewall rule is created for the gateway subnet, to the manager only" "1" \
  "$(grep -c 'firewall-rules create fxa-sandbox-allow-gw-dashboard .*--source-ranges 10.42.1.0/26 --allow tcp:8787 --target-service-accounts fxa-ai-fixme-manager@p1' "$tmp/calls")"
: > "$tmp/calls"; : > "$tmp/rule"; gw >/dev/null
check "a present rule is left alone" "0" "$(grep -c 'rules create' "$tmp/calls")"
: > "$tmp/calls"
( cd "$tmp/repo" && PATH="$tmp/bin:$PATH" FXA_GCE_PROJECT=p1 FXA_DASHBOARD_USERS='a@example.com,b@example.com' bash infra/gce/gateway.sh deploy >/dev/null 2>&1 )
check "users from .env reach the deploy" "1" "$(grep -c 'DASHBOARD_USERS=a@example.com,b@example.com' "$tmp/calls")"
ARGS=(users "x; rm -rf /"); check "users refuses anything but a comma list of emails, and calls nothing" "2|0" \
  "$( : > "$tmp/calls"; gw >/dev/null; echo $?)|$(grep -c . "$tmp/calls")"
# A quoted .env value loses both quotes; the manager is looked up in FXA_MANAGER_ZONE, never the runners' FXA_GCE_ZONE.
printf 'FXA_GCE_PROJECT="p2"\nFXA_DASHBOARD_USERS="a@example.com,b@example.com"\n' > "$tmp/repo/.env"; : > "$tmp/calls"
( cd "$tmp/repo" && PATH="$tmp/bin:$PATH" env -u FXA_GCE_PROJECT -u FXA_DASHBOARD_USERS -u FXA_MANAGER_ZONE FXA_GCE_ZONE=us-central1-a bash infra/gce/gateway.sh deploy >/dev/null 2>&1 )
check "quoted .env values arrive with no quotes" "1|1" "$(grep -c 'DASHBOARD_USERS=a@example.com,b@example.com' "$tmp/calls")|$(grep -c -- '--project p2' <<< "$(grep 'instances describe' "$tmp/calls")")"
check "the manager is found in its own zone, not the runner zone" "1|0" "$(grep -c 'instances describe fxa-manager --zone us-central1-b' "$tmp/calls")|$(grep -c 'zone us-central1-a' "$tmp/calls")"
rm -f "$tmp/repo/.env"
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
