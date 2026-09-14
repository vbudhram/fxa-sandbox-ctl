#!/bin/bash
# 12-gce-startup.sh — install the boot unit that checks out the run's branch.
set -euo pipefail

cat > /usr/local/bin/fxa-gce-checkout <<'CHECKOUT'
#!/bin/bash
# Reads fxa-branch and fxa-base from instance metadata, checks the branch out in
# the baked clone, and links /workspace. Runs after agent-init, whose firewall
# drops link-local, so the metadata read gets a one-call hole and closes it.
# The instance has no service account, so the endpoint vends no credential.
set -euo pipefail
MD=http://169.254.169.254/computeMetadata/v1/instance/attributes
iptables -I OUTPUT 1 -d 169.254.169.254 -p tcp --dport 80 -j ACCEPT
md() { curl -sf -H 'Metadata-Flavor: Google' "$MD/$1" || true; }
branch="$(md fxa-branch)"; base="$(md fxa-base)"; base="${base:-main}"
iptables -D OUTPUT -d 169.254.169.254 -p tcp --dport 80 -j ACCEPT

cd /home/agent/fxa
g() { sudo -u agent git "$@"; }
g fetch --quiet origin "$base" ${branch:+"$branch"} || true
if [ -n "$branch" ] && g rev-parse --verify --quiet "origin/$branch" >/dev/null; then
  g checkout --quiet -B "$branch" "origin/$branch"
else
  g checkout --quiet -B "${branch:-$base}" "origin/$base"
fi
if [ "$(sha256sum yarn.lock | cut -d' ' -f1)" != "$(cat .image-lock-hash)" ]; then
  sudo -u agent bash -c 'source /etc/agent-env.sh && yarn install --immutable' || true
fi
ln -sfn /home/agent/fxa /workspace
echo "fxa-gce-checkout: $(g rev-parse --abbrev-ref HEAD) at $(g rev-parse --short HEAD)"
CHECKOUT
chmod +x /usr/local/bin/fxa-gce-checkout

cat > /etc/systemd/system/fxa-gce-checkout.service <<'UNIT'
[Unit]
Description=Check out the run branch in the baked FxA clone
After=agent-init.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/fxa-gce-checkout
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
systemctl enable fxa-gce-checkout.service
echo "==> fxa-gce-checkout unit installed"
