#!/bin/bash
# 04-claude.sh — Install Claude Code CLI + Bun
set -euo pipefail

echo "==> Installing Claude Code CLI..."
npm install -g @anthropic-ai/claude-code

echo "==> Claude Code version: $(claude --version 2>/dev/null || echo 'installed')"

# Install Bun system-wide. Several Claude Code plugins (e.g. claude-mem) ship
# hooks that shell out to `bun`. Without it, every tool call spams a
# non-blocking "Bun not found" hook error inside the VM.
echo "==> Installing Bun..."
# Bun's official installer drops binaries under $HOME/.bun. We run as root in
# the provisioner, so $HOME=/root — install there, then symlink into /usr/local/bin
# so every user (admin, agent) has it on PATH.
export BUN_INSTALL=/opt/bun
mkdir -p "$BUN_INSTALL"
curl -fsSL https://bun.sh/install | bash
# The installer writes to $HOME/.bun by default; if BUN_INSTALL didn't take,
# fall back to copying from $HOME/.bun.
if [ ! -x "${BUN_INSTALL}/bin/bun" ] && [ -x "${HOME}/.bun/bin/bun" ]; then
  cp -r "${HOME}/.bun/." "${BUN_INSTALL}/"
fi
ln -sf "${BUN_INSTALL}/bin/bun" /usr/local/bin/bun
ln -sf "${BUN_INSTALL}/bin/bunx" /usr/local/bin/bunx 2>/dev/null || true
chmod -R a+rX "$BUN_INSTALL"

echo "==> Bun version: $(bun --version 2>/dev/null || echo 'install failed')"

# Note: Claude config directories for the 'agent' user are created
# in the final provisioner step (after the agent user exists).

echo "==> Claude Code + Bun installed."
