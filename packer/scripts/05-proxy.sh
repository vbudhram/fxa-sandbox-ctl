#!/bin/bash
# 05-proxy.sh — Network configuration (no proxy)
# The VM has full internet access since it's sandboxed by the VM boundary itself.
set -euo pipefail

echo "==> Network: full internet access (VM is the sandbox boundary)"

# No proxy needed — the VM itself is the security boundary.
# Agents can only modify the mounted workspace directory.

# Ensure no stale proxy configuration
rm -f /etc/squid/squid.conf /etc/squid/allowed_domains.txt 2>/dev/null || true

echo "==> Network configured (direct access, no proxy)"
