#!/bin/bash
# 06-agent-init.sh — Systemd service that starts all infra on boot
set -euo pipefail

echo "==> Creating agent-init systemd service..."

# The agent environment file (sourced by Claude Code at runtime)
cat > /etc/agent-env.sh <<'AGENTENV'
#!/bin/bash
# FxA Agent Environment Variables
# Sourced before running Claude Code or FxA services

# Claude Code. The global npm prefix is root-owned, so the agent cannot
# self-update; the attempt only prints "Auto-update failed" on every start.
# Silence it and pin the version to whatever the image was built with.
export DISABLE_AUTOUPDATER=1

# The VM has no IPv6 route, and Node 24 tries AAAA answers first, so a
# download from any dual-stack CDN dies with ENETUNREACH. On 2026-09-19 that
# left `playwright install` with firefox but no chromium or ffmpeg.
export NODE_OPTIONS="--dns-result-order=ipv4first"

# The instance has no service account and the firewall drops the agent user's
# packets to the metadata server, so a Google client library probing for
# default credentials sits in SYN-SENT until it gives up. On 2026-09-19 that
# held every /cms/config call in the auth server for over 75 s. Tell
# gcp-metadata the server is absent and name a project so nothing looks one up.
export METADATA_SERVER_DETECTION=none
export GOOGLE_CLOUD_PROJECT=demo-fxa

# MySQL
export AUTH_MYSQL_HOST=localhost
export AUTH_MYSQL_PORT=3306
export AUTH_MYSQL_DATABASE=fxa
export AUTH_MYSQL_USERNAME=root
export AUTH_MYSQL_PASSWORD=

export PROFILE_MYSQL_HOST=localhost
export PROFILE_MYSQL_PORT=3306
export PROFILE_MYSQL_DATABASE=fxa_profile
export PROFILE_MYSQL_USERNAME=root
export PROFILE_MYSQL_PASSWORD=

export OAUTH_MYSQL_HOST=localhost
export OAUTH_MYSQL_PORT=3306
export OAUTH_MYSQL_DATABASE=fxa_oauth
export OAUTH_MYSQL_USERNAME=root
export OAUTH_MYSQL_PASSWORD=

export PUSHBOX_MYSQL_HOST=localhost
export PUSHBOX_MYSQL_PORT=3306
export PUSHBOX_MYSQL_DATABASE=pushbox
export PUSHBOX_MYSQL_USERNAME=root
export PUSHBOX_MYSQL_PASSWORD=

# Redis
export REDIS_HOST=localhost
export REDIS_PORT=6379
export ACCESS_TOKEN_REDIS_HOST=localhost
export ACCESS_TOKEN_REDIS_PORT=6379
export REFRESH_TOKEN_REDIS_HOST=localhost
export REFRESH_TOKEN_REDIS_PORT=6379
export SESSIONS_REDIS_HOST=localhost
export SESSIONS_REDIS_PORT=6379
export EMAIL_CONFIG_REDIS_HOST=localhost
export EMAIL_CONFIG_REDIS_PORT=6379
export CUSTOMS_REDIS_HOST=localhost
export CUSTOMS_REDIS_PORT=6379
export RATELIMIT_REDIS_HOST=localhost
export RATELIMIT_REDIS_PORT=6379

# Firestore
export FIRESTORE_EMULATOR_HOST=localhost:9090

# goaws (SNS/SQS)
export SNS_TOPIC_ENDPOINT=http://localhost:4100
export AWS_ACCESS_KEY_ID=fake
export AWS_SECRET_ACCESS_KEY=fake
export AWS_REGION=us-east-1

# FxA misc
export NODE_ENV=development
export FXA_L10N_SKIP=true
export PROXY_SETTINGS=true

# Playwright / functional tests
export NODE_OPTIONS="--dns-result-order=ipv4first --max-old-space-size=4096"
AGENTENV
chmod 644 /etc/agent-env.sh

# The boot service script
cat > /usr/local/bin/agent-init.sh <<'INITSCRIPT'
#!/bin/bash
# agent-init: start all infrastructure services on boot
set -euo pipefail

log() { echo "[agent-init] $(date '+%H:%M:%S') $*"; }

log "Starting infrastructure services..."

# ── Egress firewall: block access to host and private networks ──
log "Setting up egress firewall..."
GATEWAY=$(ip route | awk '/default/ {print $3}')
if [ -n "$GATEWAY" ]; then
  iptables -A OUTPUT -o lo -j ACCEPT
  iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
  # Allow DNS to the gateway and to the configured resolvers. On GCE the
  # resolver is the metadata server, which the link-local drop below would
  # otherwise silence; port 53 there is DNS only, the metadata API is port 80.
  for ns in $GATEWAY $(awk '/^nameserver/ {print $2}' /run/systemd/resolve/resolv.conf 2>/dev/null); do
    iptables -A OUTPUT -d "$ns" -p udp --dport 53 -j ACCEPT
    iptables -A OUTPUT -d "$ns" -p tcp --dport 53 -j ACCEPT
  done
  # Block private/link-local ranges
  iptables -A OUTPUT -d 10.0.0.0/8 -j DROP
  iptables -A OUTPUT -d 172.16.0.0/12 -j DROP
  iptables -A OUTPUT -d 192.168.0.0/16 -j DROP
  # Link-local carries the metadata server. The guest agent needs it (it is what
  # delivers the ssh key, and a blocked agent delayed ssh by ~80 s); the agent
  # user must not reach it. Drop by owner, not by address.
  iptables -A OUTPUT -d 169.254.0.0/16 -m owner --uid-owner agent -j DROP
  # No trailing ACCEPT. The chain policy is already ACCEPT, and an explicit
  # rule here sat in front of the launch-time allowlist, so the agent user's
  # REJECT never saw a packet: on 2026-09-15 a runner reached example.com.
  log "Egress firewall configured (private networks blocked, public internet allowed by policy)"
else
  log "WARN: Could not determine gateway, skipping firewall"
fi

# ── Mount VirtioFS shared directories ──
log "Mounting VirtioFS shares..."
mkdir -p /mnt/shared
if mount -t virtiofs com.apple.virtio-fs.automount /mnt/shared 2>/dev/null; then
  log "VirtioFS mounted at /mnt/shared"

  # Create symlink for workspace (the only host mount)
  if [ -d /mnt/shared/workspace ]; then
    ln -sfn /mnt/shared/workspace /workspace
    log "Workspace linked: /workspace"
  fi

  # Copy node_modules to local disk and bind-mount over VirtioFS.
  # VirtioFS has intermittent EACCES permission cache bugs under heavy I/O
  # (jest reads thousands of files). Local disk eliminates this.
  if [ -d /mnt/shared/workspace/node_modules ]; then
    log "Copying node_modules to local disk (VirtioFS workaround)..."
    mkdir -p /home/agent/node_modules
    rsync -a --delete /mnt/shared/workspace/node_modules/ /home/agent/node_modules/
    mount --bind /home/agent/node_modules /workspace/node_modules
    chown -R agent:agent /home/agent/node_modules
    log "node_modules overlay ready ($(du -sh /home/agent/node_modules | cut -f1))"
  fi

  # Create writable Claude directories for agent user
  AGENT_HOME=/home/agent
  if [ -d "$AGENT_HOME" ]; then
    su - agent -c 'mkdir -p ~/.claude/{debug,todos,projects,plans,tasks,cache,statsig,telemetry,session-env,backups,skills,ide,plugins,usage-data,paste-cache,file-history,shell-snapshots,chrome,memory}'
    su - agent -c 'mkdir -p ~/.config/claude/claude-code'
    log "Claude directories created for agent user"

    # Install Playwright browsers from workspace's pinned version (system deps
    # are already installed in the golden image by 08-playwright.sh)
    if [ -d /workspace/packages/functional-tests ]; then
      log "Installing Playwright browsers from workspace..."
      su - agent -c 'source /etc/agent-env.sh && cd /workspace/packages/functional-tests && npx playwright install firefox chromium 2>&1' || \
        log "WARN: Playwright browser install failed"
    fi
  fi
  # NOTE: Claude config files (settings.json, CLAUDE.md) are copied by the
  # host-side agent.sh via tart exec — NOT mounted from the host filesystem.
  # This prevents exposing sensitive host data (history, cookies, session data).
else
  log "WARN: VirtioFS mount failed (shared dirs unavailable)"
fi

# ── Detect VM IP and configure FxA service URLs ──
VM_IP=$(hostname -I | awk '{print $1}')
if [ -n "$VM_IP" ]; then
  log "VM IP: ${VM_IP} — configuring FxA service URLs..."
  cat >> /etc/agent-env.sh <<URLENV

# VM IP (used by fxa-start to build PM2 configs with correct URLs)
export VM_IP=${VM_IP}

# Bind addresses — services must listen on all interfaces for host access
export IP_ADDRESS=0.0.0.0
export HOST=0.0.0.0
export HOST_INTERNAL=0.0.0.0
export WORKER_HOST=0.0.0.0

# Rate limiting disabled — no customs server in sandbox
export CUSTOMS_SERVER_URL=none

# NOTE: Service URLs (PUBLIC_URL, PROFILE_SERVER_URL, etc.) are NOT set here.
# They are set per-process in fxa-start's PM2 configs. Setting them globally
# would override the test harness's mock server URLs and break integration tests.
URLENV
  log "FxA service URLs configured for ${VM_IP}"
else
  log "WARN: Could not detect VM IP, FxA URLs will use localhost"
fi

# ── Start MySQL ──
log "Starting MySQL..."
systemctl start mysql
for i in $(seq 1 30); do
  if mysqladmin ping -u root --silent 2>/dev/null; then
    log "MySQL ready."
    break
  fi
  sleep 1
done

# ── Start Redis ──
log "Starting Redis..."
systemctl start redis-server
for i in $(seq 1 10); do
  if redis-cli ping 2>/dev/null | grep -q PONG; then
    log "Redis ready."
    break
  fi
  sleep 1
done

# ── Start Firestore emulator ──
log "Starting Firestore emulator..."
systemctl start firestore-emulator || log "WARN: Firestore emulator failed to start"

# ── Start goaws ──
if [ -f /usr/local/bin/goaws ]; then
  log "Starting goaws..."
  systemctl start goaws || log "WARN: goaws failed to start"
fi

# ── Run FxA DB migrations if workspace is mounted ──
if [ -d /workspace/packages/db-migrations ]; then
  log "Running FxA DB migrations..."
  source /etc/agent-env.sh
  cd /workspace
  node packages/db-migrations/bin/patcher.mjs 2>/dev/null || \
    log "WARN: DB migrations failed (may need yarn install first)"
fi

log "Infrastructure ready."
INITSCRIPT
chmod +x /usr/local/bin/agent-init.sh

# Systemd unit
cat > /etc/systemd/system/agent-init.service <<'UNIT'
[Unit]
Description=FxA Agent Infrastructure Init
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/agent-init.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

systemctl enable agent-init

echo "==> agent-init service installed and enabled."
