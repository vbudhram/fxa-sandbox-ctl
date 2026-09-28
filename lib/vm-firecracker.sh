#!/bin/bash
# vm-firecracker.sh: a spike. With FXA_FC_HOST set, runners whose name matches
# FXA_FC_NAMES (default: Slack sessions) are Firecracker slots on that host
# (infra/firecracker/fc), restored from a snapshot with the FxA stack running.
# Other runners stay GCE instances. Sourced by vm-gce.sh: ssh, put and pull are
# the GCE ones, pointed at the slot's routed address by a per-host ssh entry.
[ -n "${FXA_FC_HOST:-}" ] || return 0
[ -n "${_FXA_VM_FC_LOADED:-}" ] && return 0
_FXA_VM_FC_LOADED=1

_fc() {
  # shellcheck disable=SC2029  # the arguments are ours, expanded on purpose
  ssh -i "$FXA_GCE_SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -o ConnectTimeout=20 "${USER}@${FXA_FC_HOST}" "sudo /usr/local/sbin/fc $*"
}
_fc_owns() { case "$1" in ${FXA_FC_NAMES:-agent-*}) return 0 ;; *) return 1 ;; esac; }
_fc_slot_of() { _fc list | awk -F'\t' -v n="$(vm_name "$1")" '$2 == n { print $1 }'; }

# Keep the GCE versions under _gce_ names and dispatch on the runner name.
for _f in vm_exists vm_clone vm_start vm_is_running vm_stop vm_delete vm_list; do
  eval "$(declare -f "$_f" | sed "1s/^$_f /_gce_$_f /")"
  eval "$_f() { if _fc_owns \"\${1:-}\"; then _fc_$_f \"\$@\"; else _gce_$_f \"\$@\"; fi; }"
done
unset _f

_fc_vm_exists() { [ -n "$(_fc_slot_of "$1")" ]; }
_fc_vm_is_running() { _fc_vm_exists "$1"; }
_fc_vm_clone() {
  local name="$1" out t0; t0="$(date +%s)"
  echo "Restoring '$(vm_name "$name")' from the Firecracker snapshot on ${FXA_FC_HOST}..."
  out="$(_fc claim "$(vm_name "$name")")" || return 1
  printf 'Host %s\n  HostName %s\n' "$(vm_name "$name")" "${out#* }" > "${_GCE_SSH_HOSTS}/$(vm_name "$name")"
  # The slot answers ssh already; no gcloud first login.
  touch "${LOG_DIR}/${name}.ssh-ok"
  echo "  slot ${out%% *} at ${out#* } ($(( $(date +%s) - t0 ))s)"
}
# A slot has no stopped state: a stop drops it, and a start restores a new one.
_fc_vm_start() { _fc_vm_is_running "$1" || _fc_vm_clone "$1"; }
_fc_vm_stop() { _fc_vm_delete "$1"; }
_fc_vm_delete() {
  local name="$1" n; n="$(_fc_slot_of "$name")"
  echo "Stopping slot ${n:-?} ($(vm_name "$name"))..."
  [ -n "$n" ] && _fc stop "$n" >/dev/null
  rm -f "${LOG_DIR}/${name}.ssh-ok"; _gce_ssh_forget "$name"
}
# The GCE list plus the slots, in the same name, status, age form.
vm_list() {
  _gce_vm_list
  _fc list 2>/dev/null | awk -F'\t' '{ printf "%s\tRUNNING\t%s\n", $2, $4 }' || true
}
