#!/bin/bash
# agent-startup.sh — Runs inside the VM after boot
# This script is the entrypoint for the screen session that hosts Claude Code.
# It sources the FxA environment, ensures the workspace is ready, and launches Claude.
set -euo pipefail

# ── Source environment ─────────────────────────────────────────
if [ -f /etc/agent-env.sh ]; then
  source /etc/agent-env.sh
fi

# ── Verify workspace mount ────────────────────────────────────
if [ ! -d /workspace ]; then
  echo "ERROR: /workspace is not mounted. The VirtioFS mount may have failed."
  echo "Check that the host directory was passed to 'tart run --dir=workspace:<path>'"
  echo ""
  echo "Press Enter to open a shell..."
  read -r
  exec bash
fi

cd /workspace

# ── Wait for infrastructure ───────────────────────────────────
echo "Waiting for infrastructure services..."

# Wait for MySQL
for i in $(seq 1 30); do
  if mysqladmin ping -u root --silent 2>/dev/null; then
    echo "  MySQL: ready"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "  MySQL: TIMEOUT (continuing anyway)"
  fi
  sleep 1
done

# Wait for Redis
for i in $(seq 1 10); do
  if redis-cli ping 2>/dev/null | grep -q PONG; then
    echo "  Redis: ready"
    break
  fi
  if [ "$i" -eq 10 ]; then
    echo "  Redis: TIMEOUT (continuing anyway)"
  fi
  sleep 1
done

echo "  Firestore: localhost:9090 (emulator)"
echo "  goaws: localhost:4100 (SNS/SQS)"
echo ""

# ── Workspace info ────────────────────────────────────────────
echo "=== FxA Agent Sandbox ==="
echo "  Workspace: /workspace"
echo "  Node:      $(node --version 2>/dev/null || echo 'not found')"
echo ""

if [ -f /workspace/package.json ]; then
  echo "  FxA monorepo detected."
  if [ ! -d /workspace/node_modules ]; then
    echo "  NOTE: node_modules not found. You may need to run 'yarn install'."
  fi
fi

echo ""
echo "Starting Claude Code..."
echo "─────────────────────────────────────────────"

# ── Launch Claude Code ────────────────────────────────────────
# The --dangerously-skip-permissions flag is safe here because
# the VM is the security boundary.

# If a prompt was provided via environment variable, use it
if [ -n "${CLAUDE_INITIAL_PROMPT:-}" ]; then
  exec claude --dangerously-skip-permissions -p "$CLAUDE_INITIAL_PROMPT"
else
  exec claude --dangerously-skip-permissions
fi
