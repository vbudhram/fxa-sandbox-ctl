#!/bin/bash
# vm-gce.sh — the GCE implementation of the VM backend contract.
#
# One instance per run, no service account, no external IP. The laptop reaches it
# over ssh through an IAP tunnel. The per-agent key that _install_ssh_key writes
# works unchanged: VM_SSH_OPTS carries the ProxyCommand and vm_ip returns the
# instance name, so every `ssh -i key agent@$(vm_ip)` call site keeps working.
#
# There is no shared filesystem. vm_start ignores the workspace and gitdir
# arguments; agent_run ships the run files with vm_put and finish pulls the
# tree back with vm_pull_tree.
[ -n "${_FXA_VM_GCE_LOADED:-}" ] && return 0
_FXA_VM_GCE_LOADED=1

if [ -z "${FXA_GCE_PROJECT:-}" ]; then
  echo "ERROR: FXA_VM_BACKEND=gce needs FXA_GCE_PROJECT." >&2
  return 1
fi
GCE_BOOT_TIMEOUT=180  # VM_BOOT_TIMEOUT is readonly and sized for Tart

# The operator's ~/.ssh/google_compute_engine may carry a passphrase, which a
# non-interactive poll loop cannot answer. The backend uses its own key.
FXA_GCE_SSH_KEY="${FXA_GCE_SSH_KEY:-${HOME}/.ssh/fxa-sandbox-gce}"
[ -f "$FXA_GCE_SSH_KEY" ] || ssh-keygen -t ed25519 -f "$FXA_GCE_SSH_KEY" -N "" -q -C fxa-sandbox-gce

_gce() { gcloud --project "$FXA_GCE_PROJECT" --quiet --verbosity=error "$@"; }
_gce_zone() { local sub="$1"; shift; _gce compute "$sub" "$@" --zone "$FXA_GCE_ZONE"; }
_gce_ssh() { local name="$1"; shift; _gce_zone ssh "$(vm_name "$name")" --tunnel-through-iap --ssh-key-file "$FXA_GCE_SSH_KEY" "$@"; }

# The call sites expand VM_SSH_OPTS unquoted, so an option with spaces cannot
# ride in it. The IAP ProxyCommand goes in a config file instead.
_GCE_SSH_CONFIG="${LOG_DIR}/gce-ssh-config"
mkdir -p "${LOG_DIR}"
printf 'Host %s-*\n  ProxyCommand gcloud --project %s --verbosity=error compute start-iap-tunnel %%h 22 --listen-on-stdin --zone %s\n' \
  "$VM_PREFIX" "$FXA_GCE_PROJECT" "$FXA_GCE_ZONE" > "$_GCE_SSH_CONFIG"
VM_SSH_OPTS="${VM_SSH_OPTS} -F ${_GCE_SSH_CONFIG}"

# ── Image management ───────────────────────────────────────────

vm_image_list()   { _gce compute images list --filter "name=${FXA_GCE_IMAGE}" --format 'value(name,creationTimestamp)'; }
vm_image_exists() { _gce compute images describe "$FXA_GCE_IMAGE" >/dev/null 2>&1; }
vm_image_build() {
  command -v packer &>/dev/null || { echo "ERROR: Packer not installed. Run: brew install hashicorp/tap/packer" >&2; return 1; }
  cd "${SANDBOX_ROOT}/packer"
  packer init fxa-dev.pkr.hcl
  packer build -only 'googlecompute.*' -var "project=${FXA_GCE_PROJECT}" -var "zone=${FXA_GCE_ZONE}" fxa-dev.pkr.hcl
}

# ── VM lifecycle ───────────────────────────────────────────────

vm_exists() { _gce_zone instances describe "$(vm_name "$1")" >/dev/null 2>&1; }

# vm_clone <name>
#   Create the instance. It boots at once; vm_start is then a no-op. The run's
#   branch travels as instance metadata for the image's checkout unit.
#   FXA_GCE_IMAGE_FAMILY overrides the custom image, for smoke tests on stock Ubuntu.
vm_clone() {
  local name="$1"
  if vm_exists "$name"; then
    echo "ERROR: instance '$(vm_name "$name")' already exists. Stop it first or use a different name." >&2
    return 1
  fi
  local -a image_flags=(--image "$FXA_GCE_IMAGE")
  [ -n "${FXA_GCE_IMAGE_FAMILY:-}" ] && image_flags=(--image-family "$FXA_GCE_IMAGE_FAMILY" --image-project "${FXA_GCE_IMAGE_PROJECT:-ubuntu-os-cloud}")
  mkdir -p "${LOG_DIR}"
  echo "Creating GCE instance '$(vm_name "$name")' (${FXA_GCE_MACHINE_TYPE}, ${FXA_GCE_ZONE})..."
  _gce_zone instances create "$(vm_name "$name")" \
    --machine-type "$FXA_GCE_MACHINE_TYPE" \
    "${image_flags[@]}" \
    --boot-disk-type hyperdisk-balanced --boot-disk-size 50GB \
    --network "$FXA_GCE_NETWORK" --subnet "$FXA_GCE_NETWORK" --no-address \
    --no-service-account --no-scopes \
    --metadata "fxa-branch=${FXA_GCE_BRANCH:-},fxa-base=${FXA_WORKTREE_BASE:-main}" \
    --labels "fxa-agent=${name}" \
    > "${LOG_DIR}/${name}-vm.log" 2>&1 || { cat "${LOG_DIR}/${name}-vm.log" >&2; return 1; }
}

# Machine shape is fixed by FXA_GCE_MACHINE_TYPE.
vm_configure() { :; }

# vm_start <name> <workspace_dir> <gitdir>
#   After a stop (agent_switch), start again. A fresh instance is already running.
vm_start() {
  local name="$1"
  vm_is_running "$name" && return 0
  _gce_zone instances start "$(vm_name "$name")" >/dev/null
}

vm_wait_ready() {
  local name="$1" timeout="${2:-$GCE_BOOT_TIMEOUT}" started
  started="$(date +%s)"
  echo "Waiting for ssh on '$(vm_name "$name")'..."
  while [ $(( $(date +%s) - started )) -lt "$timeout" ]; do
    if _gce_ssh "$name" --command true >/dev/null 2>&1; then
      echo "VM '$(vm_name "$name")' ready ($(( $(date +%s) - started ))s)"
      # The image's checkout unit must finish before anything touches /workspace.
      # A stock image (smoke tests) has no unit; is-enabled fails and we return.
      _gce_ssh "$name" --command 'systemctl is-enabled fxa-gce-checkout' >/dev/null 2>&1 || return 0
      echo "Waiting for fxa-gce-checkout..."
      while [ $(( $(date +%s) - started )) -lt "$timeout" ]; do
        _gce_ssh "$name" --command 'systemctl is-active fxa-gce-checkout' 2>/dev/null | grep -q '^active$' && return 0
        sleep 5
      done
      echo "ERROR: fxa-gce-checkout did not finish in ${timeout}s" >&2
      return 1
    fi
    sleep 5
  done
  echo "ERROR: no ssh on '$(vm_name "$name")' after ${timeout}s" >&2
  return 1
}

# vm_exec <name> <cmd...>
#   Same argv contract as `tart exec`: runs as root inside the instance.
vm_exec() {
  local name="$1"; shift
  _gce_ssh "$name" --command "sudo $(printf '%q ' "$@")"
}

vm_exec_as_agent() {
  local name="$1"; shift
  _gce_ssh "$name" --command "sudo -u agent -i bash -c $(printf '%q' "$*")"
}

# vm_put <name> <local-tar> <remote-dir>
#   Build the tar with COPYFILE_DISABLE=1 or macOS adds ._* AppleDouble files.
vm_put() {
  local name="$1" tar="$2" dir="$3"
  _gce_ssh "$name" --command "sudo mkdir -p '${dir}' && sudo tar -xf - -C '${dir}' && sudo chown -R agent:agent '${dir}'" < "$tar"
}

# vm_pull_tree <name> <remote-dir> <local-dir>
#   Exactly three excludes. Everything else goes through worktree_filtered_status,
#   the same filter a Tart run's tree gets.
vm_pull_tree() {
  local name="$1" remote="$2" local_dir="$3"
  local key="${LOG_DIR}/ssh/${name}/id_ed25519"
  # shellcheck disable=SC2086  # VM_SSH_OPTS is a list of flags, split on purpose
  rsync -a --delete --exclude .git --exclude node_modules --exclude external/l10n \
    -e "ssh -i ${key} ${VM_SSH_OPTS}" \
    "${VM_SSH_USER}@$(vm_ip "$name"):${remote%/}/" "${local_dir%/}/"
}

# ssh resolves the instance name through the ProxyCommand.
vm_ip() { vm_name "$1"; }

vm_is_running() {
  [ "$(_gce_zone instances describe "$(vm_name "$1")" --format 'value(status)' 2>/dev/null)" = "RUNNING" ]
}

vm_stop() {
  echo "Stopping instance '$(vm_name "$1")'..."
  _gce_zone instances stop "$(vm_name "$1")" >/dev/null 2>&1 || true
}

vm_delete() {
  local name="$1"
  echo "Deleting instance '$(vm_name "$name")'..."
  _gce_zone instances delete "$(vm_name "$name")" >/dev/null 2>&1 \
    || echo "WARN: delete failed for $(vm_name "$name"); it is still billing. Retry: fxa-sandbox-ctl --backend gce stop ${name}" >&2
  rm -f "${LOG_DIR}/${name}.pid" "${LOG_DIR}/${name}-vm.log"
}

vm_list() { _gce_zone instances list --filter "name~^${VM_PREFIX}-" --format 'value(name,status)' 2>/dev/null || true; }
