#!/bin/bash
# config.sh — Constants and defaults for fxa-sandbox-ctl

# Include guard — prevent re-sourcing readonly errors
[ -n "${_FXA_CONFIG_LOADED:-}" ] && return 0
_FXA_CONFIG_LOADED=1

# A transient GitHub or Jira failure used to abort the pass (a 5xx in the drain
# on 2026-09-14). Two retries with a short backoff, then the caller's own error
# path. Every call these wrap is idempotent: reads, label swaps, reactions.
_retry() { local d; for d in 3 9 0; do "$@" && return 0; [ "$d" = 0 ] && return 1; sleep "$d"; done; }
gh()   { _retry command gh "$@"; }
acli() { _retry command acli "$@"; }

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
# Not readonly: the gce backend appends an IAP ProxyCommand.
# ServerAlive: ConnectTimeout covers only the TCP connect. A tunnel that dies
# mid-session (the runner hit its lifetime cap) otherwise hangs the rsync and
# every pass behind it forever; on 2026-09-14 one sat for 53 min.
VM_SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o ServerAliveInterval=10 -o ServerAliveCountMax=3"

# GCE backend. Project is required when FXA_VM_BACKEND=gce.
FXA_GCE_PROJECT="${FXA_GCE_PROJECT:-}"
FXA_GCE_ZONE="${FXA_GCE_ZONE:-us-central1-a}"
# Zones to try in order when the first is stocked out. All in one region, so
# the subnet and NAT serve every one. A runner remembers the zone it landed in.
FXA_GCE_ZONES="${FXA_GCE_ZONES:-us-central1-a us-central1-b us-central1-c us-central1-f}"
FXA_GCE_IMAGE="${FXA_GCE_IMAGE:-fxa-dev-base}"
# c4a, not n4a: n4a was stocked out in every us-central1 zone on 2026-09-13.
FXA_GCE_MACHINE_TYPE="${FXA_GCE_MACHINE_TYPE:-c4a-highcpu-4}"
# A --functional-tests run holds the whole stack, the admin server and two
# Firefox workers at once. Measured on 2026-09-19 with the trimmed stack: peak
# 6.7GB of 7.9GB on an 8GB highcpu-4 over a 39-test targeted run, no OOM. The
# earlier OOM had three workers and an admin build on top. Set c4a-standard-4
# (16GB) here if a run ever needs more.
FXA_GCE_MACHINE_TYPE_FUNCTIONAL="${FXA_GCE_MACHINE_TYPE_FUNCTIONAL:-c4a-highcpu-4}"
FXA_GCE_NETWORK="${FXA_GCE_NETWORK:-fxa-sandbox}"
# List price of one runner-hour, for the dashboard's burn rate. c4a-highcpu-4 on demand.
FXA_GCE_HOURLY_USD="${FXA_GCE_HOURLY_USD:-0.13}"
# Hard lifetime for a runner. GCE deletes it at this age, whatever the laptop is doing.
FXA_GCE_MAX_RUN_SECONDS="${FXA_GCE_MAX_RUN_SECONDS:-5400}"

# Screen session name inside the VM (for Claude Code TUI)
readonly VM_SCREEN_SESSION="claude"

# Paths on macOS host for Claude config (used to copy specific files only)
readonly CLAUDE_HOME_DIR="${HOME}/.claude"
readonly CODEX_HOME_DIR="${CODEX_HOME:-${HOME}/.codex}"

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
