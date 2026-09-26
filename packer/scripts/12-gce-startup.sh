#!/bin/bash
# 12-gce-startup.sh — install the boot unit that links /workspace to the baked clone.
set -euo pipefail

cat > /usr/local/bin/fxa-gce-checkout <<'CHECKOUT'
#!/bin/bash
# Links /workspace to the baked clone. Runs as root at boot.
set -euo pipefail
# The firewall blocks the metadata DNS, so sudo cannot resolve the hostname and
# warns on every call. Pin it.
grep -q "$(hostname)" /etc/hosts || echo "127.0.1.1 $(hostname)" >> /etc/hosts
# The host pins the exact commit right after boot, and installs dependencies
# only when that commit's yarn.lock differs from the image's. A fetch here was
# redundant with it and cost 25-40 s on a fresh disk. Link and finish.
ln -sfn /home/agent/fxa /workspace
echo "fxa-gce-checkout: linked /workspace to the baked clone at $(sudo -u agent git -C /home/agent/fxa rev-parse --short HEAD)"
CHECKOUT
chmod +x /usr/local/bin/fxa-gce-checkout

cat > /etc/systemd/system/fxa-gce-checkout.service <<'UNIT'
[Unit]
Description=Link /workspace to the baked FxA clone
After=agent-init.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/fxa-gce-checkout
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
systemctl enable fxa-gce-checkout.service
echo "==> fxa-gce-checkout unit installed"
