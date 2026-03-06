#!/bin/bash
# 03-infra.sh — MySQL 8.0, Redis, Firestore emulator, goaws
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# ── MySQL 8.0 ──────────────────────────────────────────────────
echo "==> Installing MySQL 8.0..."
apt-get install -y -qq mysql-server

echo "==> Configuring MySQL..."
# Bind to localhost only
cat > /etc/mysql/mysql.conf.d/fxa.cnf <<'MYCNF'
[mysqld]
bind-address = 127.0.0.1
default-authentication-plugin = mysql_native_password
# FxA uses utf8mb4
character-set-server = utf8mb4
collation-server = utf8mb4_bin
# Cap buffer pool to prevent MySQL from consuming too much RAM on 8GB VMs
innodb_buffer_pool_size = 256M
MYCNF

# Start MySQL to create databases
systemctl start mysql

echo "==> Creating FxA databases..."
mysql -u root <<'SQL'
CREATE DATABASE IF NOT EXISTS fxa;
CREATE DATABASE IF NOT EXISTS fxa_profile;
CREATE DATABASE IF NOT EXISTS fxa_oauth;
CREATE DATABASE IF NOT EXISTS pushbox;

-- Ensure root can connect without password from localhost
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '';
FLUSH PRIVILEGES;
SQL

systemctl stop mysql
systemctl enable mysql

# ── nginx (reverse proxy for content/settings) ───────────────
echo "==> Installing nginx..."
apt-get install -y -qq nginx
systemctl disable nginx  # managed by fxa-start, not systemd
systemctl stop nginx 2>/dev/null || true

# ── Redis ──────────────────────────────────────────────────────
echo "==> Installing Redis..."
apt-get install -y -qq redis-server

# Bind to localhost, disable protected mode for local dev
sed -i 's/^bind .*/bind 127.0.0.1/' /etc/redis/redis.conf
sed -i 's/^protected-mode yes/protected-mode no/' /etc/redis/redis.conf
systemctl enable redis-server

# ── Java (for Firestore emulator) ─────────────────────────────
echo "==> Installing Java (for Firestore emulator)..."
apt-get install -y -qq default-jre-headless

# ── Firebase / Firestore emulator ─────────────────────────────
echo "==> Installing Firebase CLI (for Firestore emulator)..."
npm install -g firebase-tools

# Create Firestore emulator config
mkdir -p /opt/firestore
cat > /opt/firestore/firebase.json <<'FIREBASE'
{
  "emulators": {
    "firestore": {
      "host": "127.0.0.1",
      "port": 9090
    },
    "ui": {
      "enabled": false
    }
  }
}
FIREBASE

# Create systemd service for Firestore emulator
cat > /etc/systemd/system/firestore-emulator.service <<'UNIT'
[Unit]
Description=Firebase Firestore Emulator
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/firestore
ExecStart=/usr/local/bin/firebase emulators:start --only firestore --project fxa-dev
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemctl enable firestore-emulator

# ── goaws (SNS/SQS emulator) ─────────────────────────────────
echo "==> Installing goaws..."
GOAWS_VERSION="0.4.2"
ARCH=$(dpkg --print-architecture)

# goaws doesn't have official ARM64 binaries — use Go to build from source
apt-get install -y -qq golang-go 2>/dev/null || true

if command -v go &>/dev/null; then
  echo "==> Building goaws from source..."
  GOPATH=/tmp/gopath go install github.com/Admiral-Piett/goaws/v2/cmd/goaws@latest 2>/dev/null || {
    echo "WARN: goaws build failed, creating stub config. goaws will need manual setup."
    mkdir -p /opt/goaws
    touch /opt/goaws/goaws
  }
  if [ -f /tmp/gopath/bin/goaws ]; then
    cp /tmp/gopath/bin/goaws /usr/local/bin/goaws
    chmod +x /usr/local/bin/goaws
  fi
else
  echo "WARN: Go not available, skipping goaws build."
  mkdir -p /opt/goaws
fi

# goaws config
mkdir -p /opt/goaws
cat > /opt/goaws/goaws.yaml <<'GOAWSCFG'
Local:
  Host: 127.0.0.1
  Port: 4100
  Region: us-east-1
  AccountId: "000000000000"
  LogToFile: false
  QueueAttributeDefaults:
    VisibilityTimeout: 30
    ReceiveMessageWaitTimeSeconds: 0
  Queues:
    - Name: fxa-account-change-queue
    - Name: fxa-email-bounce-queue
    - Name: fxa-email-complaint-queue
  Topics:
    - Name: fxa-account-change
      Subscriptions:
        - QueueName: fxa-account-change-queue
          Protocol: sqs
          Raw: true
GOAWSCFG

# systemd service for goaws
cat > /etc/systemd/system/goaws.service <<'UNIT'
[Unit]
Description=GoAWS SNS/SQS Emulator
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/goaws
ExecStart=/usr/local/bin/goaws
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

if [ -f /usr/local/bin/goaws ]; then
  systemctl enable goaws
fi

# ── Cloud Tasks emulator ────────────────────────────────────
echo "==> Installing Cloud Tasks emulator..."
# The auth server's dev.json sets useLocalEmulator=true, which makes the
# Cloud Tasks gRPC client connect to localhost:8123. Without this emulator,
# accountDestroy returns 500 after deleting the account because the
# post-delete Cloud Tasks enqueue call fails.
CLOUD_TASKS_VERSION="1.2.0"
CLOUD_TASKS_URL="https://github.com/aertje/cloud-tasks-emulator/releases/download/v${CLOUD_TASKS_VERSION}/cloud-tasks-emulator-v${CLOUD_TASKS_VERSION}-linux-arm64.tar.gz"
if curl -sfL "$CLOUD_TASKS_URL" -o /tmp/cloud-tasks-emulator.tar.gz; then
  tar xzf /tmp/cloud-tasks-emulator.tar.gz -C /tmp
  mv /tmp/cloud-tasks-emulator /usr/local/bin/cloud-tasks-emulator
  chmod +x /usr/local/bin/cloud-tasks-emulator
  rm -f /tmp/cloud-tasks-emulator.tar.gz
  echo "==> Cloud Tasks emulator installed."
else
  echo "WARN: Failed to download cloud-tasks-emulator. accountDestroy may fail."
fi

# ── Pubsub emulator ──────────────────────────────────────────
echo "==> Setting up Pub/Sub emulator config..."
# gcloud pubsub emulator can be used if needed; for now we rely on the
# firebase setup. The port 8085 is reserved for it.

echo "==> Infrastructure installed."
echo "  MySQL:     localhost:3306 (databases: fxa, fxa_profile, fxa_oauth, pushbox)"
echo "  Redis:     localhost:6379"
echo "  Firestore: localhost:9090"
echo "  goaws:     localhost:4100"
echo "  CloudTasks: localhost:8123 (started by fxa-start)"
