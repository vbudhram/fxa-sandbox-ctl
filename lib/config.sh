#!/bin/bash
# config.sh — Constants and defaults for fxa-sandbox-ctl

# Include guard — prevent re-sourcing readonly errors
[ -n "${_FXA_CONFIG_LOADED:-}" ] && return 0
_FXA_CONFIG_LOADED=1

# Ensure ~/bin is on PATH (tart, packer may be installed there)
export PATH="${HOME}/bin:${PATH}"

# Golden image name (built by Packer)
readonly FXA_IMAGE_NAME="fxa-dev-base"

# VM defaults
readonly DEFAULT_VM_CPU=4
readonly DEFAULT_VM_MEMORY_MB=8192  # 8 GB
readonly MIN_HOST_FREE_RAM_MB=4096  # Warn if less than 4GB free on host

# VM name prefix (VMs are named agent-<name>)
readonly VM_PREFIX="agent"

# SSH defaults for VMs
readonly VM_SSH_USER="agent"
readonly VM_SSH_PASS="agent"
readonly VM_SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5"

# Screen session name inside the VM (for Claude Code TUI)
readonly VM_SCREEN_SESSION="claude"

# Paths on macOS host for Claude config (used to copy specific files only)
readonly CLAUDE_HOME_DIR="${HOME}/.claude"

# VirtioFS mount names (used by tart run --dir)
readonly MOUNT_WORKSPACE="workspace"

# Sandbox root (where this script lives)
SANDBOX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SANDBOX_ROOT

# Log directory
readonly LOG_DIR="${SANDBOX_ROOT}/logs"

# Staggered startup delay between VMs (seconds)
readonly VM_START_DELAY=5

# Boot timeout (seconds to wait for SSH readiness)
readonly VM_BOOT_TIMEOUT=60
