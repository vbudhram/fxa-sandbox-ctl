#!/bin/bash
# 02-node.sh — Node.js toolchain (node 22, corepack, yarn, nx, pm2)
set -euo pipefail

NODE_VERSION="22"

echo "==> Installing Node.js ${NODE_VERSION} via NodeSource..."
curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash -
apt-get install -y -qq nodejs

echo "==> Node version: $(node --version)"
echo "==> npm version: $(npm --version)"

echo "==> Enabling corepack (for yarn)..."
corepack enable

echo "==> Installing global npm packages..."
npm install -g \
  nx@latest \
  pm2@latest

echo "==> Node toolchain installed."
echo "  node: $(node --version)"
echo "  npm:  $(npm --version)"
echo "  nx:   $(nx --version 2>/dev/null || echo 'installed')"
echo "  pm2:  $(pm2 --version 2>/dev/null || echo 'installed')"
