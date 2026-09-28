#!/bin/bash
# vm-tart.sh: the Tart implementation of the VM backend contract.

if [ -z "${FXA_IMAGE_NAME:-}" ]; then
  source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
fi

# ── Image management ───────────────────────────────────────────

vm_image_list() {
  tart list 2>/dev/null | grep "^${FXA_IMAGE_NAME} "
}

vm_image_exists() {
  tart list 2>/dev/null | grep -q "${FXA_IMAGE_NAME}"
}

vm_image_build() {
  if ! command -v packer &>/dev/null; then
    echo "ERROR: Packer not installed. Run: brew install hashicorp/tap/packer" >&2
    return 1
  fi

  echo "Building golden image '${FXA_IMAGE_NAME}'..."
  echo "This will take 10-20 minutes on first run."

  cd "${SANDBOX_ROOT}/packer"
  packer init fxa-dev.pkr.hcl
  packer build -only 'tart-cli.*' fxa-dev.pkr.hcl
}

# ── VM lifecycle ───────────────────────────────────────────────

vm_exists() {
  tart list 2>/dev/null | grep -q "$(vm_name "$1")"
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
  tart set "$(vm_name "$1")" --cpu "${2:-$DEFAULT_VM_CPU}" --memory "${3:-$DEFAULT_VM_MEMORY_MB}"
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

  local tart_cmd=(
    tart run --no-graphics
    "--dir=${MOUNT_WORKSPACE}:${workspace_dir}"
  )

  # The parent .git holds the admin dir of EVERY worktree, so it mounts READ-ONLY:
  # read-write, an agent once rewrote three sibling worktrees' gitdir files. The VM
  # only reads it to resolve its own .git pointer. A permissions error here means
  # something tries to write, which is the bug; do not drop the `:ro`.
  if [ -n "$gitdir" ]; then
    tart_cmd+=("--dir=gitdir:${gitdir}:ro")
  fi

  # ~/.claude is never mounted: it holds tokens, cookies and history.
  # _setup_claude_config copies only the files the VM needs.
  tart_cmd+=("${full_name}")

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

    # tart exec works once the guest agent is up.
    if tart exec "${full_name}" true 2>/dev/null; then
      echo "VM '${full_name}' ready (${elapsed}s)"
      return 0
    fi

    sleep 2
  done
}

vm_exec() {
  local name="$1"; shift
  tart exec "$(vm_name "$name")" "$@"
}

vm_exec_as_agent() {
  local name="$1"; shift
  tart exec "$(vm_name "$name")" sudo -u agent -i bash -c "$*"
}

vm_ip() {
  local ip
  ip="$(tart ip "$(vm_name "$1")" 2>/dev/null)" || return 1
  [ -n "$ip" ] || return 1
  echo "$ip"
}

vm_stop() {
  local full_name
  full_name="$(vm_name "$1")"
  echo "Stopping VM '${full_name}'..."
  # A clean shutdown first, then a forced stop.
  tart exec "${full_name}" sudo shutdown -h now 2>/dev/null || true
  sleep 3
  tart stop "${full_name}" 2>/dev/null || true
}

vm_delete() {
  local name="$1"
  echo "Deleting VM '$(vm_name "$name")'..."
  tart delete "$(vm_name "$name")" 2>/dev/null || true
  rm -f "${LOG_DIR}/${name}.pid" "${LOG_DIR}/${name}-vm.log"
}

# tart reports an IP only for a running VM.
vm_is_running() {
  tart ip "$(vm_name "$1")" &>/dev/null
}

vm_list() {
  tart list 2>/dev/null | grep "${VM_PREFIX}-" || true
}

# A stopped Tart VM keeps its .meta on purpose (switch and attach reuse it).
vm_gc() { :; }
