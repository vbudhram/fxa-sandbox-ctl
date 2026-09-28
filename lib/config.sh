#!/bin/bash
# config.sh: constants and defaults for fxa-sandbox-ctl.

# Re-sourcing would fail on the readonly assignments.
[ -n "${_FXA_CONFIG_LOADED:-}" ] && return 0
_FXA_CONFIG_LOADED=1

# A transient GitHub or Jira failure used to abort the pass (a 5xx in the drain
# on 2026-09-14). Two retries with a short backoff, then the caller's own error
# path. Every call these wrap is idempotent: reads, label swaps, reactions.
_retry() { local d; for d in 3 9 0; do "$@" && return 0; [ "$d" = 0 ] && return 1; sleep "$d"; done; }
gh()   { _retry command gh "$@"; }
acli() { _retry command acli "$@"; }

# tart and packer may live in ~/bin.
export PATH="${HOME}/bin:${PATH}"
# Host git never runs a hook or fsmonitor command: a slot's tree and hooks are agent-written.
export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null \
  GIT_CONFIG_KEY_1=core.fsmonitor GIT_CONFIG_VALUE_1=false

readonly FXA_IMAGE_NAME="fxa-dev-base"  # the Packer-built golden image

readonly DEFAULT_VM_CPU=4
readonly DEFAULT_VM_MEMORY_MB=8192  # 8 GB
readonly MIN_HOST_FREE_RAM_MB=4096  # Warn if less than 4GB free on host

readonly VM_PREFIX="agent"  # VMs are named agent-<name>
readonly VM_SSH_USER="agent"
# Not readonly: the gce backend appends an IAP ProxyCommand. Through a proxy,
# ConnectTimeout also bounds the wait for the ssh banner, and an IAP tunnel
# often needs more than 5 s for that. ServerAlive stops a tunnel that dies
# mid-session from hanging the rsync and every pass behind it.
VM_SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=${FXA_SSH_CONNECT_TIMEOUT:-30} -o ServerAliveInterval=10 -o ServerAliveCountMax=3"

# GCE backend. Project is required when FXA_VM_BACKEND=gce.
FXA_GCE_PROJECT="${FXA_GCE_PROJECT:-}"
FXA_GCE_ZONE="${FXA_GCE_ZONE:-us-central1-a}"
# Zones to try in order when the first is stocked out. All in one region, so
# the subnet and NAT serve every one. A runner remembers the zone it landed in.
FXA_GCE_ZONES="${FXA_GCE_ZONES:-us-central1-a us-central1-b us-central1-c us-central1-f}"
FXA_GCE_IMAGE="${FXA_GCE_IMAGE:-fxa-dev-base}"
# c4a, not n4a: n4a was stocked out in every us-central1 zone on 2026-09-13.
FXA_GCE_MACHINE_TYPE="${FXA_GCE_MACHINE_TYPE:-c4a-highcpu-4}"
# A --functional-tests run (stack, admin server, two Firefox workers) peaked at
# 6.7GB of 8GB, no OOM. Set c4a-standard-4 (16GB) if a run ever needs more.
FXA_GCE_MACHINE_TYPE_FUNCTIONAL="${FXA_GCE_MACHINE_TYPE_FUNCTIONAL:-c4a-highcpu-4}"
FXA_GCE_NETWORK="${FXA_GCE_NETWORK:-fxa-sandbox}"
# Manager service account from infra/gce/setup.sh. gcloud reads this variable
# on every call, ssh's IAP ProxyCommand included, so one export covers them all.
FXA_GCE_SERVICE_ACCOUNT="${FXA_GCE_SERVICE_ACCOUNT:-}"
[ -n "$FXA_GCE_SERVICE_ACCOUNT" ] && export CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT="$FXA_GCE_SERVICE_ACCOUNT"
# List price of one runner-hour, for the dashboard's burn rate. c4a-highcpu-4 on demand.
FXA_GCE_HOURLY_USD="${FXA_GCE_HOURLY_USD:-0.13}"
# Hard lifetime for a runner. GCE deletes it at this age, whatever the laptop is doing.
FXA_GCE_MAX_RUN_SECONDS="${FXA_GCE_MAX_RUN_SECONDS:-5400}"

readonly VM_SCREEN_SESSION="claude"

# Host config dirs; only specific files from them are copied into the VM.
readonly CLAUDE_HOME_DIR="${HOME}/.claude"
readonly CODEX_HOME_DIR="${CODEX_HOME:-${HOME}/.codex}"

readonly MOUNT_WORKSPACE="workspace"  # VirtioFS mount name for tart run --dir

SANDBOX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SANDBOX_ROOT
readonly LOG_DIR="${SANDBOX_ROOT}/logs"

readonly VM_BOOT_TIMEOUT=60  # seconds to wait for the VM to answer
