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
