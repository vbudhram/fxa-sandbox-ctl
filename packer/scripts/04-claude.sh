#!/bin/bash
# 04-claude.sh — Install Claude Code CLI
set -euo pipefail

echo "==> Installing Claude Code CLI..."
npm install -g @anthropic-ai/claude-code

echo "==> Claude Code version: $(claude --version 2>/dev/null || echo 'installed')"

# Note: Claude config directories for the 'agent' user are created
# in the final provisioner step (after the agent user exists).

echo "==> Claude Code installed."
