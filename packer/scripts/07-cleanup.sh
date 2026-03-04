#!/bin/bash
# 07-cleanup.sh — Trim the golden image
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "==> Cleaning up to reduce image size..."

# Clean apt cache
apt-get autoremove -y -qq
apt-get clean
rm -rf /var/lib/apt/lists/*

# Clean npm cache
npm cache clean --force 2>/dev/null || true

# Clean Go build artifacts (if Go was installed for goaws)
rm -rf /tmp/gopath
rm -rf /root/go

# Clean temp files
rm -rf /tmp/*
rm -rf /var/tmp/*

# Clear logs
find /var/log -type f -name "*.log" -exec truncate -s 0 {} \;
journalctl --vacuum-time=1s 2>/dev/null || true

# Zero free space for better compression (optional, can be slow)
# dd if=/dev/zero of=/EMPTY bs=1M 2>/dev/null || true
# rm -f /EMPTY

echo "==> Cleanup complete."
echo "==> Golden image is ready."
