#!/bin/bash
# 09-fxa-services.sh — Install FXA service launcher for sandbox VMs
set -euo pipefail

echo "==> Installing FXA service launcher..."

# Create the fxa-start script that agents can run inside the VM
cat > /usr/local/bin/fxa-start <<'FXASTART'
#!/bin/bash
# fxa-start — Start FXA application services in the sandbox VM
#
# Usage:
#   fxa-start              Start all FXA services
#   fxa-start --status     Show service status
#   fxa-start --stop       Stop all FXA services
#
# Infrastructure (MySQL, Redis, Firestore, goaws) is started at boot
# by agent-init. This script starts the Node.js application services.
set -euo pipefail

log() { echo "[fxa-start] $(date '+%H:%M:%S') $*"; }

if [ ! -f /etc/agent-env.sh ]; then
  echo "ERROR: /etc/agent-env.sh not found. Is this a sandbox VM?" >&2
  exit 1
fi

source /etc/agent-env.sh

# Detect VM IP for URL configuration
VM_IP=$(hostname -I | awk '{print $1}')
VM_IP=${VM_IP:-localhost}

if [ ! -d /workspace/packages ]; then
  echo "ERROR: /workspace not mounted. Start VM with workspace directory." >&2
  exit 1
fi

cd /workspace

# ── Subcommands ──

case "${1:-}" in
  --status)
    pm2 list 2>/dev/null || echo "PM2 not running"
    exit 0
    ;;
  --stop)
    log "Stopping FXA services..."
    pm2 kill 2>/dev/null || true
    # Stop nginx reverse proxy if running
    if [ -f /tmp/nginx.pid ]; then
      nginx -c /tmp/fxa-proxy.conf -s stop 2>/dev/null || true
    fi
    log "Done."
    exit 0
    ;;
esac

MINIMAL=false

# ── Step 1: Install missing Linux-arm64 native modules ──
# The workspace node_modules were installed on macOS (darwin-arm64).
# We use npm pack to fetch the corresponding linux-arm64 binaries.
install_linux_pkg() {
  local linux_pkg="$1" darwin_pkg="$2"
  if [ -d "node_modules/${linux_pkg}" ]; then
    return 0  # already installed
  fi
  if [ ! -d "node_modules/${darwin_pkg}" ]; then
    return 0  # darwin package not present, skip
  fi
  local version
  version=$(node -p "require('./node_modules/${darwin_pkg}/package.json').version")
  log "Installing ${linux_pkg}@${version}..."
  mkdir -p "node_modules/${linux_pkg}"
  local tgz_name
  tgz_name=$(npm pack "${linux_pkg}@${version}" --pack-destination /tmp 2>/dev/null | tail -1)
  if [ -n "$tgz_name" ] && [ -f "/tmp/${tgz_name}" ]; then
    tar xzf "/tmp/${tgz_name}" -C "node_modules/${linux_pkg}" --strip-components=1
    rm -f "/tmp/${tgz_name}"
    log "Installed ${linux_pkg}@${version}"
  else
    log "WARN: Failed to install ${linux_pkg}"
  fi
}

log "Fixing platform-specific native modules for Linux..."
install_linux_pkg "@esbuild/linux-arm64" "@esbuild/darwin-arm64"
install_linux_pkg "sass-embedded-linux-arm64" "sass-embedded-darwin-arm64"
install_linux_pkg "@swc/core-linux-arm64-gnu" "@swc/core-darwin-arm64"
npm rebuild esbuild sass-embedded @swc/core 2>&1 | tail -3 || \
  log "WARN: npm rebuild had errors (non-critical, other esbuild versions in monorepo)"
log "Native modules ready."

# ── Step 2: Run DB patches ──
log "Running DB patches..."
node packages/db-migrations/bin/patcher.mjs 2>&1 | tail -3 || \
  log "WARN: DB patches failed (may already be applied)"

# ── Step 3: Create nginx reverse proxy for static assets ──
# The content server proxies React routes to settings (:3000) via
# PROXY_SETTINGS=true, but does NOT proxy /static/* asset requests.
# nginx sits on :3030, routes /static/* to settings (:3000), and
# forwards everything else to the content server on :3031.
#
# The key feature is sub_filter: it rewrites VM_IP URLs in responses
# to use $host (the request's Host header). This fixes the origin
# mismatch when tests inside the VM access via localhost:
#   - From host (192.168.64.39): $host=192.168.64.39, no-op rewrite
#   - From VM  (localhost):      $host=localhost, rewrites IP→localhost
#
# The content server keeps PUBLIC_URL=http://$VM_IP:3030 so all its
# server-side logic (sessions, cookies, redirects) works correctly.
# Only the HTML/JSON response bodies are rewritten for the browser.
#
# IMPORTANT: proxy_set_header must be in EVERY location block because
# nginx does not inherit server-level proxy_set_header when a location
# block defines its own. Each location needs Host + Accept-Encoding.
#
# NOTE: The heredoc is UNQUOTED so $VM_IP expands at script time,
# but nginx variables ($host, $http_upgrade) are escaped with \.
cat > /tmp/fxa-proxy.conf <<NGINXCONF
worker_processes 1;
pid /tmp/nginx.pid;
error_log /tmp/nginx-error.log;

events {
    worker_connections 256;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /tmp/nginx-access.log;

    # Temp paths writable without root
    client_body_temp_path /tmp/nginx-client-body;
    proxy_temp_path /tmp/nginx-proxy;
    fastcgi_temp_path /tmp/nginx-fastcgi;
    uwsgi_temp_path /tmp/nginx-uwsgi;
    scgi_temp_path /tmp/nginx-scgi;

    # Only send "upgrade" Connection header for WebSocket requests
    map \$http_upgrade \$connection_upgrade {
        default upgrade;
        ''      '';
    }

    server {
        listen 3030;
        server_name _;

        # Strip HSTS — content server sends strict-transport-security over
        # plain HTTP, which causes browsers to upgrade requests to HTTPS.
        proxy_hide_header strict-transport-security;

        # Rewrite VM IP URLs to match the actual request host.
        # From host (VM_IP): no-op (VM_IP -> VM_IP).
        # From VM (localhost): rewrites VM_IP -> localhost.
        # Both literal and URL-encoded forms needed (meta tag is URL-encoded).
        sub_filter 'http://${VM_IP}:' 'http://\$host:';
        sub_filter 'http%3A%2F%2F${VM_IP}%3A' 'http%3A%2F%2F\$host%3A';
        sub_filter_once off;
        sub_filter_types text/html application/json text/javascript application/javascript;

        # Settings static assets -> settings dev server (:3000)
        location /static/ {
            proxy_pass http://127.0.0.1:3000;
            proxy_http_version 1.1;
            proxy_set_header Host \$http_host;
            proxy_set_header Accept-Encoding "";
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
        }
        location /settings/static/ {
            rewrite ^/settings/static/(.*) /static/\$1 break;
            proxy_pass http://127.0.0.1:3000;
            proxy_set_header Host \$http_host;
            proxy_set_header Accept-Encoding "";
        }
        location ~ ^/(sockjs-node|ws|locales/|legal-docs/|assets/|lang-fix\\.js|query-fix\\.js|favicon\\.(ico|png)|manifest\\.json) {
            proxy_pass http://127.0.0.1:3000;
            proxy_http_version 1.1;
            proxy_set_header Host \$http_host;
            proxy_set_header Accept-Encoding "";
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
        }

        # Inbox viewer — self-contained HTML page for reading captured emails
        location = /__inbox {
            alias /tmp/inbox-viewer.html;
            default_type text/html;
        }

        # Mail API proxy — avoids CORS when inbox viewer fetches from mail_helper
        location /__mail/ {
            rewrite ^/__mail/(.*)$ /mail/\$1 break;
            proxy_pass http://127.0.0.1:9001;
            proxy_http_version 1.1;
            proxy_set_header Host \$http_host;
            proxy_set_header Accept-Encoding "";
            proxy_read_timeout 5s;
        }

        # Everything else -> content server (:3031)
        location / {
            proxy_pass http://127.0.0.1:3031;
            proxy_http_version 1.1;
            proxy_set_header Host \$http_host;
            proxy_set_header Accept-Encoding "";
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
        }
    }
}
NGINXCONF

# ── Step 3b: Ensure goaws (SNS/SQS emulator) is running ──
# The auth server publishes to SNS on account events. If the Go-built goaws
# binary is missing (common on ARM64), start a minimal Node.js stub.
if ! curl -sf http://localhost:4100/ >/dev/null 2>&1; then
  log "goaws not responding on :4100, starting Node.js SNS stub..."
  cat > /tmp/goaws-stub.js <<'GOAWSSTUB'
const http = require("http");
const server = http.createServer((req, res) => {
  let body = "";
  req.on("data", (c) => (body += c));
  req.on("end", () => {
    const action = body.match(/Action=(\w+)/)?.[1] || "Unknown";
    if (action === "Publish") {
      res.writeHead(200, { "Content-Type": "text/xml" });
      res.end('<PublishResponse xmlns="http://sns.amazonaws.com/doc/2010-03-31/"><PublishResult><MessageId>stub-' + Date.now() + '</MessageId></PublishResult></PublishResponse>');
    } else if (action === "CreateTopic") {
      res.writeHead(200, { "Content-Type": "text/xml" });
      res.end('<CreateTopicResponse xmlns="http://sns.amazonaws.com/doc/2010-03-31/"><CreateTopicResult><TopicArn>arn:aws:sns:us-east-1:000000000000:stub-topic</TopicArn></CreateTopicResult></CreateTopicResponse>');
    } else if (action === "Subscribe") {
      res.writeHead(200, { "Content-Type": "text/xml" });
      res.end('<SubscribeResponse xmlns="http://sns.amazonaws.com/doc/2010-03-31/"><SubscribeResult><SubscriptionArn>arn:aws:sns:us-east-1:000000000000:stub-topic:stub-sub</SubscriptionArn></SubscribeResult></SubscribeResponse>');
    } else {
      res.writeHead(200, { "Content-Type": "text/xml" });
      res.end('<Response><RequestId>stub</RequestId></Response>');
    }
  });
});
server.listen(4100, "127.0.0.1", () => console.log("[goaws-stub] SNS stub on :4100"));
GOAWSSTUB
  pm2 start /tmp/goaws-stub.js --name goaws-stub 2>&1 | tail -3
fi

# ── Step 3c: Ensure Cloud Tasks emulator is running ──
# The auth server's dev.json sets useLocalEmulator=true, which makes the
# Cloud Tasks client connect to localhost:8123 via gRPC. Without an emulator,
# accountDestroy returns 500 after successfully deleting the account because
# the post-delete Cloud Tasks enqueue call fails.
#
# IMPORTANT: The emulator must be running BEFORE the auth server starts,
# because the gRPC client may not reconnect if the initial connection fails.
# We check via PM2 process list (not HTTP, since this is a gRPC server).
if command -v cloud-tasks-emulator >/dev/null 2>&1; then
  if ! pm2 describe cloud-tasks-emulator >/dev/null 2>&1; then
    log "Starting Cloud Tasks emulator on :8123..."
    pm2 start cloud-tasks-emulator --name cloud-tasks-emulator -- \
      -host "0.0.0.0" -port "8123" \
      -queue "projects/test/locations/test/queues/delete-accounts-queue" \
      -queue "projects/test/locations/test/queues/inactive-first-email" \
      -queue "projects/test/locations/test/queues/inactive-second-email" \
      -queue "projects/test/locations/test/queues/inactive-third-email" \
      2>&1 | tail -3
    sleep 2  # Give gRPC server time to bind
  else
    log "Cloud Tasks emulator already running."
  fi
else
  log "WARN: cloud-tasks-emulator not installed; accountDestroy may return 500"
fi

# ── Step 4: Start FXA application services via PM2 ──
log "Starting FXA services..."

# Auth server (port 9000) — core authentication API
# We use a custom PM2 config to override PUBLIC_URL and OAUTH_URL to localhost.
# The global agent-env.sh sets these to the VM IP for external access, but
# the auth server derives its JWT issuer domain from PUBLIC_URL. The oauth
# assertion verification expects "localhost:9000" (from dev.json), so we
# must match that. Services bind to 0.0.0.0 so they're still reachable
# from the host Mac via the VM IP.
cat > /tmp/auth-pm2.config.js <<'AUTHPM2'
const base = require("/workspace/packages/fxa-auth-server/pm2.config.js");
const apps = (base.apps || [base]).map(app => ({
  ...app,
  env: {
    ...app.env,
    PUBLIC_URL: "http://localhost:9000",
    OAUTH_URL: "http://localhost:9000",
    CONTENT_SERVER_URL: "http://localhost:3030",
    CUSTOMS_SERVER_URL: "none",
    PROFILE_SERVER_URL: "http://localhost:1111",
    // Disable Stripe/subscriptions — the sandbox has no Stripe/Play/AppStore
    // backends. When stripeApiKey is set (even to "NOT SET" from dev.json),
    // the JWT access token path calls capabilityService.subscriptionCapabilities()
    // which times out (~42s) trying to reach those APIs.
    // Setting SUBHUB_STRIPE_APIKEY="" causes CapabilityService to use a mock
    // StripeHelper that returns empty results instantly. PlayBilling and
    // AppleIAP also gracefully return [] when not configured.
    SUBHUB_STRIPE_APIKEY: "",
    SUBSCRIPTIONS_ENABLED: "false",
    MAILER_HOST: "0.0.0.0",
  },
}));
module.exports = { apps };
AUTHPM2
pm2 start /tmp/auth-pm2.config.js 2>&1 | tail -3

# Content server (port 3031, internal) — behind the nginx reverse proxy
# We use a custom PM2 config to override PORT from 3030 to 3031.
#
# URL overrides: The content server embeds these into HTML <meta name="fxa-config">
# tags which the BROWSER reads. We use $VM_IP so the server-side logic
# (sessions, cookies, redirects) works correctly. The nginx sub_filter
# rewrites VM_IP → $host in response bodies so in-VM browsers see
# localhost URLs that match their origin. The heredoc is unquoted so
# $VM_IP expands.
cat > /tmp/content-pm2.config.js <<CONTENTPM2
module.exports = {
  apps: [{
    name: "content",
    script: "node server/bin/fxa-content-server.js",
    cwd: "/workspace/packages/fxa-content-server",
    watch: ["server/**/*.js", "server/**/*.html", "server/**/*.json"],
    env: {
      PORT: "3031",
      PUBLIC_URL: "http://$VM_IP:3030",
      FXA_URL: "http://$VM_IP:9000",
      FXA_OAUTH_URL: "http://$VM_IP:9000",
      FXA_PROFILE_URL: "http://$VM_IP:1111",
      FXA_PROFILE_IMAGES_URL: "http://$VM_IP:1112",
      PROXY_SETTINGS: "true",
      NODE_ENV: "development",
      NODE_OPTIONS: "--openssl-legacy-provider --dns-result-order=ipv4first",
      CONFIG_FILES: "server/config/local.json",
    },
  }],
};
CONTENTPM2
pm2 start /tmp/content-pm2.config.js 2>&1 | tail -3

# Reverse proxy (port 3030) — nginx routes static assets to settings,
# rewrites localhost URLs to match browser origin via sub_filter.
nginx -c /tmp/fxa-proxy.conf
log "nginx reverse proxy started on :3030"

# Settings (port 3000) — React settings UI
pm2 start packages/fxa-settings/pm2.config.js 2>&1 | tail -3

# Profile server (port 1111) — user profile API
# Inter-service URLs use localhost (same VM). IMG_URL uses $VM_IP since
# it appears in API responses consumed by the browser.
cat > /tmp/profile-pm2.config.js <<PROFILEPM2
const base = require("/workspace/packages/fxa-profile-server/pm2.config.js");
const apps = (base.apps || [base]).map(app => ({
  ...app,
  env: {
    ...app.env,
    AUTH_SERVER_URL: "http://localhost:9000/v1",
    OAUTH_SERVER_URL: "http://localhost:9000/v1",
    WORKER_URL: "http://localhost:1113",
    IMG_URL: "http://$VM_IP:1112/a/{id}",
  },
}));
module.exports = { apps };
PROFILEPM2
pm2 start /tmp/profile-pm2.config.js 2>&1 | tail -3

# Customs/rate-limiting — DISABLED for sandbox mode
# The auth server has CUSTOMS_SERVER_URL="none" so it won't call customs.
# pm2 start packages/fxa-customs-server/pm2.config.js 2>&1 | tail -3

# Test RP (port 8080) — relying party for testing OAuth
pm2 start packages/123done/pm2.config.js 2>&1 | tail -3

# ── Step 5: Wait and report ──
log "Waiting for services to start..."
sleep 8

echo ""
pm2 list
echo ""
log "FXA services started."
echo ""
echo "  In-VM URLs (for Playwright tests):"
echo "    Content Server:  http://localhost:3030"
echo "    Auth Server:     http://localhost:9000"
echo "    Settings:        http://localhost:3000"
echo "    Profile:         http://localhost:1111"
echo "    123done (RP):    http://localhost:8080"
echo ""
echo "  Host Mac URLs (external access):"
echo "    Content Server:  http://${VM_IP}:3030"
echo "    Auth Server:     http://${VM_IP}:9000"
echo "    Profile:         http://${VM_IP}:1111"
echo "    123done (RP):    http://${VM_IP}:8080"
echo ""
echo "  Monitor logs:  pm2 logs --lines 20"
echo "  Status:        fxa-start --status"
echo "  Stop:          fxa-start --stop"

FXASTART
chmod +x /usr/local/bin/fxa-start

echo "==> FXA service launcher installed (/usr/local/bin/fxa-start)."
