#!/bin/bash
# 04b-codex.sh — Install the OpenAI Codex CLI alongside Claude Code.
# The runtime is chosen per launch (FXA_AGENT_RUNTIME), not per image, so both
# CLIs live in one golden image. Node 24 is already present from 02-node.sh.
set -euo pipefail
echo "==> Installing Codex CLI..."
npm install -g @openai/codex
echo "==> Codex version: $(codex --version 2>/dev/null || echo 'installed')"
