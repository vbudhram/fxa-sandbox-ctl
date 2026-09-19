#!/bin/bash
# infra/gce/setup.sh — one-time network for GCE runners. Idempotent.
# Runners get no external IP and no service account. Egress is Cloud NAT.
# Inbound is ssh from the IAP range only.
set -euo pipefail
: "${FXA_GCE_PROJECT:?set FXA_GCE_PROJECT}"
REGION="${FXA_GCE_REGION:-us-central1}"
NET="${FXA_GCE_NETWORK:-fxa-sandbox}"
g() { gcloud --project "$FXA_GCE_PROJECT" --quiet "$@"; }

g services enable compute.googleapis.com iap.googleapis.com
g compute networks describe "$NET" >/dev/null 2>&1 \
  || g compute networks create "$NET" --subnet-mode=custom
g compute networks subnets describe "$NET" --region "$REGION" >/dev/null 2>&1 \
  || g compute networks subnets create "$NET" --network "$NET" --region "$REGION" --range 10.42.0.0/24
g compute routers describe "$NET-router" --region "$REGION" >/dev/null 2>&1 \
  || g compute routers create "$NET-router" --network "$NET" --region "$REGION"
g compute routers nats describe "$NET-nat" --router "$NET-router" --region "$REGION" >/dev/null 2>&1 \
  || g compute routers nats create "$NET-nat" --router "$NET-router" --region "$REGION" \
       --auto-allocate-nat-external-ips --nat-all-subnet-ip-ranges
g compute firewall-rules describe "$NET-allow-iap-ssh" >/dev/null 2>&1 \
  || g compute firewall-rules create "$NET-allow-iap-ssh" --network "$NET" \
       --direction INGRESS --allow tcp:22 --source-ranges 35.235.240.0/20
echo "ok: network $NET in $REGION"

# Manager service account. The laptop impersonates it (no key file): runners
# and their ssh-key metadata, the IAP tunnel, and the state bucket only.
# The operator mints its tokens, so a cron pass no longer dies with the
# operator's SSO session. Image builds stay on the operator's own account.
SA="fxa-ai-fixme-manager@${FXA_GCE_PROJECT}.iam.gserviceaccount.com"
OP="${FXA_GCE_OPERATOR:-$(gcloud config get-value account 2>/dev/null)}"
g iam service-accounts describe "$SA" >/dev/null 2>&1 \
  || g iam service-accounts create fxa-ai-fixme-manager --display-name "fxa-ai-fixme manager"
for r in roles/compute.instanceAdmin.v1 roles/iap.tunnelResourceAccessor; do
  g projects add-iam-policy-binding "$FXA_GCE_PROJECT" --member "serviceAccount:$SA" --role "$r" --condition=None >/dev/null
done
g storage buckets add-iam-policy-binding "gs://${FXA_GCE_PROJECT}-fxa-ai-fixme" \
  --member "serviceAccount:$SA" --role roles/storage.objectAdmin >/dev/null
g iam service-accounts add-iam-policy-binding "$SA" --member "user:${OP}" --role roles/iam.serviceAccountTokenCreator >/dev/null
echo "ok: $SA; add FXA_GCE_SERVICE_ACCOUNT=$SA to .env"
