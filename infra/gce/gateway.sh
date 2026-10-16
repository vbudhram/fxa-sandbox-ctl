#!/bin/bash
# infra/gce/gateway.sh: the dashboard gateway (desktop-gateway/ on Cloud Run, behind IAP) and the
# firewall rule that lets it reach the manager's dashboard on :8787, in code instead of by hand.
#   bash infra/gce/gateway.sh plan             what deploy would set; changes nothing
#   bash infra/gce/gateway.sh deploy           build desktop-gateway/ and deploy it, then make sure of the rule
#   bash infra/gce/gateway.sh users <a,b,...>  set only DASHBOARD_USERS (who may see the dashboard)
# Values that stay out of this public repo come from the controller's .env: FXA_DASHBOARD_USERS and
# FXA_GATEWAY_IAP_AUDIENCE. Unset, the service keeps the values it has: --update-env-vars and
# --update-secrets change only what they name. Every command here changes GCP: run it as the operator.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [ -f "$ROOT/.env" ]; then
  while IFS='=' read -r k v; do case "$k" in FXA_GCE_PROJECT|FXA_DASHBOARD_USERS|FXA_GATEWAY_IAP_AUDIENCE) [ -n "${!k:-}" ] || export "$k=${v%\"}" ;; esac; done < "$ROOT/.env"
fi
P="${FXA_GCE_PROJECT:?FXA_GCE_PROJECT is not set (controller .env)}"
R="${FXA_GATEWAY_REGION:-us-central1}" SVC="${FXA_GATEWAY_SERVICE:-fxa-desktop}" NET="${FXA_GCE_NETWORK:-fxa-sandbox}"
SUBNET="${FXA_GATEWAY_SUBNET:-fxa-desktop-gw}" GW_SA="fxa-desktop-gw@${P}.iam.gserviceaccount.com"
MGR_SA="fxa-ai-fixme-manager@${P}.iam.gserviceaccount.com" RULE="${NET}-allow-gw-dashboard"
EMAILS='^[^@,; ]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}(,[^@,; ]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})*$'

# The env to set: the bucket and the manager URL are derived; the rest only when .env names them.
want_env() {
  local ip; ip="$(gcloud compute instances describe fxa-manager --zone "${FXA_GCE_ZONE:-us-central1-b}" --project "$P" --format='value(networkInterfaces[0].networkIP)')"
  [[ "$ip" =~ ^[0-9.]+$ ]] || { echo "ERROR: no private IP for fxa-manager" >&2; return 1; }
  printf 'DESKTOP_BUCKET=%s;MANAGER_URL=http://%s:8787' "${P}-fxa-ai-fixme" "$ip"
  [ -z "${FXA_GATEWAY_IAP_AUDIENCE:-}" ] || printf ';IAP_AUDIENCE=%s' "$FXA_GATEWAY_IAP_AUDIENCE"
  if [ -n "${FXA_DASHBOARD_USERS:-}" ]; then
    [[ "$FXA_DASHBOARD_USERS" =~ $EMAILS ]] || { echo "ERROR: FXA_DASHBOARD_USERS is not a comma list of emails" >&2; return 1; }
    printf ';DASHBOARD_USERS=%s' "$FXA_DASHBOARD_USERS"
  fi
}

# The rule: the gateway's subnet may reach the dashboard port, on the manager only.
ensure_rule() {
  local src; src="$(gcloud compute networks subnets describe "$SUBNET" --region "$R" --project "$P" --format='value(ipCidrRange)')"
  if gcloud compute firewall-rules describe "$RULE" --project "$P" >/dev/null 2>&1; then echo "firewall rule ${RULE}: present"
  else
    gcloud compute firewall-rules create "$RULE" --project "$P" --network "$NET" --direction INGRESS \
      --source-ranges "$src" --allow tcp:8787 --target-service-accounts "$MGR_SA" --quiet && echo "firewall rule ${RULE}: created"
  fi
}

case "${1:-}" in
  plan)
    env="$(want_env)"
    echo "service ${SVC} in ${R}: account ${GW_SA}, network ${NET}/${SUBNET}, private-ranges egress, at most 1 instance"
    echo "env it sets: $(printf '%s' "$env" | tr ';' '\n' | cut -d= -f1 | paste -sd, -) (each other value stays as it is)"
    [ -z "${FXA_DASHBOARD_USERS:-}" ] || echo "dashboard users: $(tr ',' '\n' <<< "$FXA_DASHBOARD_USERS" | grep -c .)"
    echo "secret: DASHBOARD_HMAC from fxa-dashboard-hmac"
    live="$(gcloud run services describe "$SVC" --region "$R" --project "$P" --format=json 2>/dev/null)" || live='{}'
    echo "now: $(jq -r '[.spec.template.spec.containers[0].env[]?.name] | join(",")' <<< "$live")"
    # Say which values a deploy would change; the users show as a count, never as emails.
    while IFS='=' read -r k v || [ -n "$k" ]; do
      cur="$(jq -r --arg k "$k" '.spec.template.spec.containers[0].env[]? | select(.name == $k) | .value // empty' <<< "$live")"
      [ "$k" = DASHBOARD_USERS ] && v="$(tr ',' '\n' <<< "$v" | grep -c .) users" cur="$(tr ',' '\n' <<< "$cur" | grep -c .) users"
      [ "$k" = IAP_AUDIENCE ] && { [ "$v" = "$cur" ] && v=same cur=same || v=new cur=old; }
      [ "$cur" = "$v" ] && echo "  ${k}: unchanged" || echo "  ${k}: changes (${cur:-unset} -> ${v})"
    done < <(printf '%s' "$env" | tr ';' '\n')
    gcloud compute firewall-rules describe "$RULE" --project "$P" >/dev/null 2>&1 && echo "firewall rule ${RULE}: present" || echo "firewall rule ${RULE}: missing (deploy creates it)" ;;
  deploy)
    env="$(want_env)"
    gcloud run deploy "$SVC" --source "$ROOT/desktop-gateway" --region "$R" --project "$P" --service-account "$GW_SA" \
      --network "$NET" --subnet "$SUBNET" --vpc-egress private-ranges-only --max-instances 1 --cpu-boost \
      --no-allow-unauthenticated --update-env-vars "^;^${env}" --update-secrets DASHBOARD_HMAC=fxa-dashboard-hmac:latest
    ensure_rule ;;
  users)
    [[ "${2:-}" =~ $EMAILS ]] || { echo "usage: gateway.sh users <email>[,<email>...]" >&2; exit 2; }
    gcloud run services update "$SVC" --region "$R" --project "$P" --update-env-vars "^;^DASHBOARD_USERS=$2"
    echo "Put the same list in the controller .env as FXA_DASHBOARD_USERS, so the next deploy keeps it." ;;
  *) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
