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
GCE_BOOT_TIMEOUT=300      # VM_BOOT_TIMEOUT is readonly and sized for Tart. Measured: 112 s to ssh.
GCE_CHECKOUT_TIMEOUT=600  # first-boot fetch over NAT plus lazy disk hydration; measured over 180 s

# The operator's ~/.ssh/google_compute_engine may carry a passphrase, which a
# non-interactive poll loop cannot answer. The backend uses its own key.
FXA_GCE_SSH_KEY="${FXA_GCE_SSH_KEY:-${HOME}/.ssh/fxa-sandbox-gce}"
[ -f "$FXA_GCE_SSH_KEY" ] || ssh-keygen -t ed25519 -f "$FXA_GCE_SSH_KEY" -N "" -q -C fxa-sandbox-gce

_gce() { gcloud --project "$FXA_GCE_PROJECT" --quiet --verbosity=error "$@"; }
# Each instance remembers the zone it landed in (stockouts move launches
# between zones), so every per-instance call reads that file, not the default.
_vm_zone() { cat "${LOG_DIR}/${1#agent-}.zone" 2>/dev/null || printf '%s' "$FXA_GCE_ZONE"; }
_gce_zones_csv() { printf '%s' "$FXA_GCE_ZONES" | tr ' ' ','; }
# _gce_zone instances <verb> <instance> [args]   |   _gce_zone ssh <instance> [args]
_gce_zone() {
  local sub="$1"; shift
  local inst; if [ "$sub" = "ssh" ]; then inst="$1"; else inst="$2"; fi
  _gce compute "$sub" "$@" --zone "$(_vm_zone "$inst")"
}
# gcloud compute ssh spends ~3 s per call on its own key and metadata checks.
# The boot probe goes through it, which provisions the host user and key on
# the instance; every call after it is plain ssh through the IAP ProxyCommand,
# about 1.5 s.
_gce_ssh() {
  local name="$1"; shift
  if [ -f "${LOG_DIR}/${name}.ssh-ok" ]; then
    local cmd=""; [ "${1:-}" = "--command" ] && cmd="$2"
    # shellcheck disable=SC2086  # VM_SSH_OPTS is a list of flags, split on purpose
    ssh -i "$FXA_GCE_SSH_KEY" $VM_SSH_OPTS "${USER}@$(vm_name "$name")" "$cmd"
  else
    _gce_zone ssh "$(vm_name "$name")" --tunnel-through-iap --ssh-key-file "$FXA_GCE_SSH_KEY" "$@"
  fi
}

# The call sites expand VM_SSH_OPTS unquoted, so an option with spaces cannot
# ride in it. The IAP ProxyCommand goes in a config file instead.
_GCE_SSH_CONFIG="${LOG_DIR}/gce-ssh-config"
_GCE_SSH_HOSTS="${LOG_DIR}/gce-ssh-hosts"
mkdir -p "${LOG_DIR}" "${_GCE_SSH_HOSTS}"
# Per-host entries live one file each under gce-ssh-hosts/ (written at create,
# removed at delete) and reach ssh through Include. Concurrent launches then
# never rewrite a shared file: on 2026-09-18 two launchers shared one .tmp,
# one mv landed under the other's `cat - config > config.tmp`, and that cat
# copied its own output for 25 minutes. The wildcard is the default-zone fallback.
if ! grep -q "^Include ${_GCE_SSH_HOSTS}/\*$" "$_GCE_SSH_CONFIG" 2>/dev/null; then
  # No ControlMaster here, on purpose. A master whose IAP tunnel died kept
  # every later ssh to that runner queued on its socket for up to 53 min
  # (2026-09-14), and a killed master left clients hanging anyway. One tunnel
  # per call costs about 1.5 s; the launch makes ~15 calls.
  printf 'Include %s/*\nHost %s-*\n  ProxyCommand gcloud --project %s --verbosity=error compute start-iap-tunnel %%h 22 --listen-on-stdin --zone %s\n' \
    "$_GCE_SSH_HOSTS" "$VM_PREFIX" "$FXA_GCE_PROJECT" "$FXA_GCE_ZONE" > "$_GCE_SSH_CONFIG"
fi
VM_SSH_OPTS="${VM_SSH_OPTS} -F ${_GCE_SSH_CONFIG}"

# ── Image management ───────────────────────────────────────────

vm_image_list()   { _gce compute images list --filter "family=${FXA_GCE_IMAGE}" --format 'value(name,creationTimestamp)'; }
vm_image_exists() { _gce compute images describe-from-family "$FXA_GCE_IMAGE" >/dev/null 2>&1; }
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
  local -a image_flags=(--image-family "$FXA_GCE_IMAGE")
  [ -n "${FXA_GCE_IMAGE_FAMILY:-}" ] && image_flags=(--image-family "$FXA_GCE_IMAGE_FAMILY" --image-project "${FXA_GCE_IMAGE_PROJECT:-ubuntu-os-cloud}")
  mkdir -p "${LOG_DIR}"
  # One zone holds about two of these; on a stockout move to the next zone in
  # the region and remember where the instance landed.
  # A stockout lasts hours, so start with the zone the last launch landed in.
  local zone zones last
  last="$(cat "${LOG_DIR}/last-good-zone" 2>/dev/null || true)"
  zones="$FXA_GCE_ZONES"
  case " $zones " in *" $last "*) zones="$last $(printf '%s' "$zones" | tr ' ' '\n' | grep -vx "$last" | tr '\n' ' ')" ;; esac
  for zone in $zones; do
    echo "Creating GCE instance '$(vm_name "$name")' (${FXA_GCE_MACHINE_TYPE}, ${zone})..."
    if _gce compute instances create "$(vm_name "$name")" --zone "$zone" \
        --machine-type "$FXA_GCE_MACHINE_TYPE" \
        "${image_flags[@]}" \
        --boot-disk-type hyperdisk-balanced --boot-disk-size 50GB \
        --network "$FXA_GCE_NETWORK" --subnet "$FXA_GCE_NETWORK" --no-address \
        --no-service-account --no-scopes \
        --max-run-duration "${FXA_GCE_MAX_RUN_SECONDS}s" --instance-termination-action DELETE \
        --metadata "fxa-branch=${FXA_GCE_BRANCH:-},fxa-base=${FXA_WORKTREE_BASE:-main}" \
        --labels "fxa-agent=${name}" \
        > "${LOG_DIR}/${name}-vm.log" 2>&1; then
      printf '%s' "$zone" > "${LOG_DIR}/${name}.zone"
      printf '%s' "$zone" > "${LOG_DIR}/last-good-zone"
      # The IAP ProxyCommand needs the zone too; a per-host entry wins over the wildcard.
      printf 'Host %s\n  ProxyCommand gcloud --project %s --verbosity=error compute start-iap-tunnel %%h 22 --listen-on-stdin --zone %s\n' \
        "$(vm_name "$name")" "$FXA_GCE_PROJECT" "$zone" > "${_GCE_SSH_HOSTS}/$(vm_name "$name")"
      return 0
    fi
    if grep -q 'ZONE_RESOURCE_POOL_EXHAUSTED' "${LOG_DIR}/${name}-vm.log"; then
      echo "  ${zone} is stocked out for ${FXA_GCE_MACHINE_TYPE}; trying the next zone." >&2
      continue
    fi
    cat "${LOG_DIR}/${name}-vm.log" >&2; return 1
  done
  echo "ERROR: every zone in FXA_GCE_ZONES (${FXA_GCE_ZONES}) is stocked out for ${FXA_GCE_MACHINE_TYPE}." >&2
  return 1
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
      touch "${LOG_DIR}/${name}.ssh-ok"
      # The image's checkout unit must finish before anything touches /workspace.
      # A stock image (smoke tests) has no unit; is-enabled fails and we return.
      _gce_ssh "$name" --command 'systemctl is-enabled fxa-gce-checkout' >/dev/null 2>&1 || return 0
      echo "Waiting for fxa-gce-checkout..."
      local deadline=$(( $(date +%s) + GCE_CHECKOUT_TIMEOUT ))
      while [ "$(date +%s)" -lt "$deadline" ]; do
        _gce_ssh "$name" --command 'systemctl is-active fxa-gce-checkout' 2>/dev/null | grep -q '^active$' && return 0
        sleep 5
      done
      echo "ERROR: fxa-gce-checkout did not finish in ${GCE_CHECKOUT_TIMEOUT}s" >&2
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
#   Build the tar gzipped, with COPYFILE_DISABLE=1 or macOS adds ._* AppleDouble files.
vm_put() {
  local name="$1" tar="$2" dir="$3"
  # Files must belong to the agent, or tee cannot open the transcript it writes.
  # Extract as the agent, so nothing needs a chown: a chown -R here walked the
  # whole clone, node_modules included, and cost most of a launch's shipping time.
  _gce_ssh "$name" --command "sudo -u agent mkdir -p '${dir}' && sudo -u agent tar -xzf - -C '${dir}'" < "$tar"
}

# vm_pull_tree <name> <remote-dir> <local-dir>
#   Exactly three excludes. Everything else goes through worktree_filtered_status,
#   the same filter a Tart run's tree gets.
# One pass, retried after 3 s when the tunnel drops. The tree is only read for
# a PR after the handoff file exists, when the agent has stopped writing, so a
# single pass is consistent there; a convergence loop on a live tree cost three
# full pulls per poll and put a five-runner snapshot over six minutes.
vm_pull_tree() {
  local name="$1" remote="$2" local_dir="$3" i rc=1
  local key="${LOG_DIR}/ssh/${name}/id_ed25519"
  for i in 1 2 3; do
    # shellcheck disable=SC2086  # VM_SSH_OPTS is a list of flags, split on purpose
    # --safe-links: a pulled symlink pointing outside the tree is dropped, not
    # created and committed. CI and hook config stay on the runner unless the
    # ticket asks for them (the same flag finish honours).
    local -a tooling=(--exclude .github --exclude .circleci --exclude .husky)
    # bash 3.2 on macOS: "${tooling[@]}" on an empty array is an unbound
    # variable under set -u and killed the launcher on 2026-09-21.
    [ "${FXA_ALLOW_TOOLING_EDITS:-}" = "1" ] && tooling=()
    rsync -a --delete --safe-links --timeout=60 --exclude .git --exclude node_modules --exclude external/l10n \
      --exclude .nx --exclude dist --exclude coverage ${tooling[@]+"${tooling[@]}"} \
      -e "ssh -i ${key} ${VM_SSH_OPTS}" \
      "${VM_SSH_USER}@$(vm_ip "$name"):${remote%/}/" "${local_dir%/}/" 2>/dev/null && return 0
    rc=$?; sleep 3
  done
  return "$rc"
}

# ssh resolves the instance name through the ProxyCommand.
vm_ip() { vm_name "$1"; }

# One instance list answers every vm_is_running for 20 s. A snapshot asks this
# a dozen times, and each describe through gcloud costs about two seconds.
_GCE_RUNNING=""; _GCE_RUNNING_AT=0
vm_is_running() {
  local now; now="$(date +%s)"
  if [ $(( now - _GCE_RUNNING_AT )) -ge 20 ]; then
    _GCE_RUNNING="$(_gce compute instances list --zones "$(_gce_zones_csv)" --filter "name~^${VM_PREFIX}- AND status=RUNNING" --format 'value(name)' 2>/dev/null | tr '\n' ' ')"
    _GCE_RUNNING_AT="$now"
  fi
  case " $_GCE_RUNNING " in *" $(vm_name "$1") "*) return 0 ;; *) return 1 ;; esac
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
  rm -f "${LOG_DIR}/${name}.pid" "${LOG_DIR}/${name}-vm.log" "${LOG_DIR}/${name}.zone" "${LOG_DIR}/${name}.ssh-ok"
  _gce_ssh_forget "$name"
}

# Drop the per-host ssh entry, or the file grows one block per run forever.
_gce_ssh_forget() {
  rm -f "${_GCE_SSH_HOSTS}/$(vm_name "$1")"
}

# vm_gc: state files whose instance is gone. Each crash path leaves a different
# one (.meta, .zone, an ssh entry), and a leftover .meta makes freeslots and the
# dashboard treat the slot as owned. A .meta under 10 min old may belong to a
# clone still in flight, so it stays.
vm_gc() {
  local f name running; running="$(vm_list 2>/dev/null | cut -f1)"
  for f in "${LOG_DIR}"/*.meta; do
    [ -e "$f" ] || continue
    name="$(basename "$f" .meta)"
    printf '%s\n' "$running" | grep -qx "$(vm_name "$name")" && continue
    [ $(( $(date +%s) - $(stat -f %m "$f") )) -lt 600 ] && continue
    rm -f "$f" "${LOG_DIR}/${name}.zone" "${LOG_DIR}/${name}.ssh-ok"; _gce_ssh_forget "$name"
    echo "$name gc (no instance)"
  done
}

# name, status, and age in seconds. The age is what the dashboard flags.
# `instances list` takes --zones, not --zone, so it does not go through _gce_zone.
# creationTimestamp carries a UTC offset with a colon; date -j needs it without.
vm_list() {
  local n st ts
  _gce compute instances list --zones "$(_gce_zones_csv)" --filter "name~^${VM_PREFIX}-" \
       --format 'value(name,status,creationTimestamp)' 2>/dev/null \
  | while IFS=$'\t' read -r n st ts; do
      ts="$(printf '%s' "$ts" | sed -E 's/\.[0-9]+//; s/([+-][0-9]{2}):([0-9]{2})$/\1\2/')"
      printf '%s\t%s\t%s\n' "$n" "$st" "$(( $(date +%s) - $(date -j -f '%Y-%m-%dT%H:%M:%S%z' "$ts" +%s 2>/dev/null || echo 0) ))"
    done || true
}
