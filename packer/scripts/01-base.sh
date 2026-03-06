#!/bin/bash
# 01-base.sh — System packages for FxA development
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "==> Updating package lists..."
apt-get update -qq

echo "==> Installing base packages..."
apt-get install -y -qq \
  build-essential \
  git \
  curl \
  wget \
  jq \
  unzip \
  openssh-server \
  screen \
  htop \
  vim \
  ca-certificates \
  gnupg \
  lsb-release \
  python3 \
  python3-pip \
  pkg-config \
  libssl-dev \
  libgraphicsmagick1-dev \
  graphicsmagick

# Ensure SSH is enabled and hardened
echo "==> Configuring SSH..."
systemctl enable ssh
# Disable password authentication — SSH key-only access
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config

# Create 2GB swap to prevent OOM kills
echo "==> Creating 2GB swapfile..."
fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
# Low swappiness — only swap under pressure
echo 'vm.swappiness=10' >> /etc/sysctl.d/99-swap.conf

echo "==> Base packages installed."
