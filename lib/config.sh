#!/bin/bash
# config.sh: constants and defaults for fxa-sandbox-ctl.

# Re-sourcing would fail on the readonly assignments.
[ -n "${_FXA_CONFIG_LOADED:-}" ] && return 0
_FXA_CONFIG_LOADED=1

# A transient GitHub or Jira failure used to abort the pass (a 5xx in the drain
# on 2026-09-14). Two retries with a short backoff, then the caller's own error
# path. Only for calls that are safe to repeat (reads, label swaps, reactions,
# pr create); a comment post calls `command gh`/`command acli` directly.
_retry() { local d; for d in 3 9 0; do "$@" && return 0; [ "$d" = 0 ] && return 1; sleep "$d"; done; }
gh()   { _retry command gh "$@"; }
acli() { _retry command acli "$@"; }

# The host is macOS (BSD tools) or the manager VM (GNU tools). GNU `stat -f`
# describes the file system and does not fail, so choose once, not per call.
if stat -c %Y / >/dev/null 2>&1; then
  _mtime() { stat -c %Y "$1"; }
  _fsize() { stat -c %s "$1"; }
  # %W is 0 where the file system keeps no birth time; the mtime is next best.
  _btime() { local b; b="$(stat -c %W "$1")" || return 1; if [ "$b" -gt 0 ]; then echo "$b"; else stat -c %Y "$1"; fi; }
  _epoch_of() { date -u -d "$1" +%s; }
else
  _mtime() { stat -f %m "$1"; }
  _fsize() { stat -f %z "$1"; }
  _btime() { stat -f %B "$1"; }
  # BSD date wants no fraction, and an offset with no colon.
  _epoch_of() { date -j -f '%Y-%m-%dT%H:%M:%S%z' "$(printf '%s' "$1" | sed -E 's/\.[0-9]+//; s/Z$/+0000/; s/([+-][0-9]{2}):([0-9]{2})$/\1\2/')" +%s; }
fi
# Free space in whole GB on the file system holding <path> (default /).
_free_gb() { df -Pk "${1:-/}" | awk 'NR==2 {print int($4 / 1048576)}'; }

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
# Direct (the manager VM, on the private network) connects in under a second,
# so it waits less: 10 s to connect, and a dead connection is dropped after
# 15 s, which also bounds a call that lands on a dead kept-open connection.
# The margin is for a runner busy with an install, which answers slowly.
if [ "${FXA_GCE_SSH_DIRECT:-}" = 1 ]; then _ssh_ct=10 _ssh_alive=5; else _ssh_ct=30 _ssh_alive=10; fi
VM_SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=${FXA_SSH_CONNECT_TIMEOUT:-$_ssh_ct} -o ServerAliveInterval=${_ssh_alive} -o ServerAliveCountMax=3"
unset _ssh_ct _ssh_alive

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
# Always-on infrastructure at list prices, for the dashboard. The manager VM sets
# its own (e2-standard-4 and 200 GB balanced disk, about 0.16) in its .env; 0 elsewhere.
FXA_MANAGER_HOURLY_USD="${FXA_MANAGER_HOURLY_USD:-0}"
# The Firecracker host while FXA_FC_HOST is set: c3-standard-22, 300 GB SSD, 50 GB boot.
FXA_FC_HOURLY_USD="${FXA_FC_HOURLY_USD:-1.12}"
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
