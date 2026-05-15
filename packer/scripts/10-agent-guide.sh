#!/bin/bash
# 10-agent-guide.sh — Install agent guide and quick-reference into the golden image
set -euo pipefail

echo "==> Installing VM agent guide and context files..."

# ── Full guide: /etc/vm-agent-guide.md ────────────────────────
# The canonical source is VM_AGENT_GUIDE.md at the repo root, staged to
# /tmp/vm-agent-guide.md by the `file` provisioner in fxa-dev.pkr.hcl.

if [ ! -f /tmp/vm-agent-guide.md ]; then
  echo "ERROR: /tmp/vm-agent-guide.md missing. The packer `file` provisioner must run first." >&2
  exit 1
fi

install -m 0644 /tmp/vm-agent-guide.md /etc/vm-agent-guide.md
rm -f /tmp/vm-agent-guide.md
echo "==> Full VM agent guide installed at /etc/vm-agent-guide.md"

# ── Quick reference: /etc/vm-agent-context.md ─────────────────
# Compact fallback for quick lookups.

cat > /etc/vm-agent-context.md <<'VMCONTEXT'
# Sandbox VM — Quick Reference

You are inside a sandbox VM (Ubuntu 24.04 ARM64, Tart on Apple Silicon).

## Key Paths
- Workspace: /workspace
- Environment: source /etc/agent-env.sh
- Full guide: /etc/vm-agent-guide.md

## Infrastructure (auto-started at boot)
- MySQL:3306  — mysql -u root -e "SELECT 1"
- Redis:6379  — redis-cli ping
- Firestore:9090
- goaws:4100

## FxA Services (must start manually)
  fxa-start              # Start all services
  fxa-start --status     # PM2 process list
  fxa-start --stop       # Stop everything

## Port Map
- Auth server:     localhost:9000  — curl -sf http://localhost:9000/__heartbeat__
- Content (nginx): localhost:3030  — curl -sf http://localhost:3030/
- Settings:        localhost:3000
- Profile:         localhost:1111
- 123done (RP):    localhost:8080  (nginx proxy; direct on :8081)
- Email:           localhost:9001  — curl http://localhost:9001/mail
- Inbox viewer:    localhost:3030/__inbox
- Cloud Tasks:     localhost:8123

## Tests (verify services first)
  curl -sf http://localhost:9000/__heartbeat__ && echo "auth OK"
  curl -sf http://localhost:3030/ >/dev/null && echo "content OK"
  cd /workspace && yarn test-sandbox
  npx playwright test --project=sandbox tests/signin/signIn.spec.ts
  npx playwright test --project=sandbox --headed  # visible browser
  npx nx test-unit <package-name>
  npx nx lint <package-name>   # required for pipeline runs
  # WARNING: Do NOT set FXA_SANDBOX_IP inside the VM (host-only variable)

## Autonomous Pipeline (when started via `fxa-sandbox-ctl jira <KEY>`)
- Read /workspace/.fxa-jira-context.md first
- Write /workspace/.fxa-auto-done.json when finished
- Save media (optional) under /workspace/.fxa-auto-media/
- DO NOT git push or run gh. The host orchestrator handles that.
- See /etc/vm-agent-guide.md "Part 3" for full contract.

## Debugging
  pm2 status / pm2 logs --lines 50
  systemctl status agent-init
  journalctl -u agent-init --no-pager
VMCONTEXT

chmod 644 /etc/vm-agent-context.md
echo "==> VM agent quick reference installed at /etc/vm-agent-context.md"
