#!/bin/bash
# vm.sh — Tart VM lifecycle operations

# Source config if not already loaded
if [ -z "${FXA_IMAGE_NAME:-}" ]; then
  source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
fi

# ── VM naming ──────────────────────────────────────────────────

vm_name() {
  local name="$1"
  echo "${VM_PREFIX}-${name}"
}

# ── Image management ───────────────────────────────────────────

vm_image_exists() {
  tart list 2>/dev/null | grep -q "${FXA_IMAGE_NAME}"
}

vm_image_build() {
  local packer_dir="${SANDBOX_ROOT}/packer"

  if ! command -v packer &>/dev/null; then
    echo "ERROR: Packer not installed. Run: brew install hashicorp/tap/packer" >&2
    return 1
  fi

  echo "Building golden image '${FXA_IMAGE_NAME}'..."
  echo "This will take 10-20 minutes on first run."

  cd "${packer_dir}"
  packer init fxa-dev.pkr.hcl
  packer build fxa-dev.pkr.hcl
}

# ── VM lifecycle ───────────────────────────────────────────────

vm_exists() {
  local name="$1"
  tart list 2>/dev/null | grep -q "$(vm_name "$name")"
}

vm_clone() {
  local name="$1"
  local full_name
  full_name="$(vm_name "$name")"

  if ! vm_image_exists; then
    echo "ERROR: Golden image '${FXA_IMAGE_NAME}' not found." >&2
    echo "Run: fxa-sandbox-ctl image build" >&2
    return 1
  fi

  if vm_exists "$name"; then
    echo "ERROR: VM '${full_name}' already exists. Stop it first or use a different name." >&2
    return 1
  fi

  echo "Cloning '${FXA_IMAGE_NAME}' → '${full_name}'..."
  tart clone "${FXA_IMAGE_NAME}" "${full_name}"
}

vm_configure() {
  local name="$1"
  local cpu="${2:-$DEFAULT_VM_CPU}"
  local memory="${3:-$DEFAULT_VM_MEMORY_MB}"
  local full_name
  full_name="$(vm_name "$name")"

  tart set "${full_name}" --cpu "$cpu" --memory "$memory"
}

vm_start() {
  local name="$1"
  local workspace_dir="$2"
  local gitdir="${3:-}"
  local full_name
  full_name="$(vm_name "$name")"
  local log_file="${LOG_DIR}/${name}-vm.log"

  mkdir -p "${LOG_DIR}"

  echo "Starting VM '${full_name}' with workspace: ${workspace_dir}..."

  # Build tart run command with VirtioFS mounts
  local tart_cmd=(
    tart run --no-graphics
    "--dir=${MOUNT_WORKSPACE}:${workspace_dir}"
  )

  # Mount parent .git directory for worktrees
  if [ -n "$gitdir" ]; then
    tart_cmd+=("--dir=gitdir:${gitdir}")
  fi

  # NOTE: We intentionally do NOT mount ~/Library/Application Support/Claude
  # or ~/.claude into the VM. Those directories contain sensitive data (cookies,
  # token caches, conversation history, project paths). Only specific config
  # files are copied into the VM after boot via _setup_claude_config().

  tart_cmd+=("${full_name}")

  # Start VM in background
  "${tart_cmd[@]}" > "${log_file}" 2>&1 &
  local vm_pid=$!
  echo "$vm_pid" > "${LOG_DIR}/${name}.pid"

  echo "VM started (PID: ${vm_pid}). Waiting for boot..."
}

vm_wait_ready() {
  local name="$1"
  local timeout="${2:-$VM_BOOT_TIMEOUT}"
  local full_name
  full_name="$(vm_name "$name")"

  local start_time
  start_time=$(date +%s)

  while true; do
    local elapsed=$(( $(date +%s) - start_time ))
    if [ "$elapsed" -ge "$timeout" ]; then
      echo "ERROR: VM '${full_name}' did not become ready within ${timeout}s" >&2
      return 1
    fi

    # tart exec works once the VM is booted and the guest agent is ready
    if tart exec "${full_name}" true 2>/dev/null; then
      echo "VM '${full_name}' ready (${elapsed}s)"
      return 0
    fi

    sleep 2
  done
}

vm_exec() {
  local name="$1"
  shift
  local full_name
  full_name="$(vm_name "$name")"

  tart exec "${full_name}" "$@"
}

vm_exec_as_agent() {
  local name="$1"
  shift
  local full_name
  full_name="$(vm_name "$name")"

  tart exec "${full_name}" sudo -u agent -i bash -c "$*"
}

vm_ip() {
  local name="$1"
  local full_name
  full_name="$(vm_name "$name")"

  local ip
  ip="$(tart ip "${full_name}" 2>/dev/null)" || return 1
  if [ -z "$ip" ]; then
    return 1
  fi
  echo "$ip"
}

vm_stop() {
  local name="$1"
  local full_name
  full_name="$(vm_name "$name")"

  echo "Stopping VM '${full_name}'..."

  # Graceful shutdown
  tart exec "${full_name}" sudo shutdown -h now 2>/dev/null || true
  sleep 3

  # Force stop if still running
  tart stop "${full_name}" 2>/dev/null || true
}

vm_delete() {
  local name="$1"
  local full_name
  full_name="$(vm_name "$name")"

  echo "Deleting VM '${full_name}'..."
  tart delete "${full_name}" 2>/dev/null || true

  # Clean up PID and log files
  rm -f "${LOG_DIR}/${name}.pid"
  rm -f "${LOG_DIR}/${name}-vm.log"
}

vm_is_running() {
  local name="$1"
  local full_name
  full_name="$(vm_name "$name")"

  # Check if tart reports an IP (means the VM is running)
  tart ip "${full_name}" &>/dev/null
}

vm_list() {
  # List all agent VMs
  tart list 2>/dev/null | grep "${VM_PREFIX}-" || true
}
