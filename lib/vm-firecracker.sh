#!/bin/bash
# vm-firecracker.sh: with FXA_FC_HOST set, runners whose name matches FXA_FC_NAMES
# (default: Slack sessions) are Firecracker slots on that host (infra/firecracker/fc),
# restored from a snapshot with the FxA stack running. Other runners stay GCE
# instances. Sourced by vm-gce.sh: ssh, put and pull are the GCE ones, pointed at
# the slot's routed address by a per-host ssh entry.
# The host runs on demand: a session's runner starts it when it is stopped
# (FXA_FC_INSTANCE in FXA_FC_ZONE), and the host powers itself off after 30 idle
# minutes (infra/firecracker/idle-stop.sh). When it cannot start, the runner is GCE.
[ -n "${FXA_FC_HOST:-}" ] || return 0
[ -n "${_FXA_VM_FC_LOADED:-}" ] && return 0
_FXA_VM_FC_LOADED=1
FXA_FC_INSTANCE="${FXA_FC_INSTANCE:-fxa-fc-spike}"
FXA_FC_ZONE="${FXA_FC_ZONE:-us-central1-a}"

_fc_raw() {
  # shellcheck disable=SC2029  # the arguments are ours, expanded on purpose
  ssh -i "$FXA_GCE_SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -o ConnectTimeout=20 "${USER}@${FXA_FC_HOST}" "sudo /usr/local/sbin/fc $*"
}
# A stopped host has no slots: say so at once, not after a 20 s ssh timeout.
_fc() { _fc_up && _fc_raw "$@"; }

# _fc_up   The host answers ssh. A stopped host drops the probe, so every call would
# wait the full 3 s: a miss is remembered for a minute.
_fc_up() {
  local down="${TMPDIR:-/tmp}/fxa-fc-down-${USER:-u}-${FXA_FC_HOST}"
  [ -f "$down" ] && [ $(( $(date +%s) - $(_mtime "$down") )) -lt 60 ] && return 1
  timeout 3 bash -c ": </dev/tcp/${FXA_FC_HOST}/22" 2>/dev/null && { rm -f "$down"; return 0; }
  touch "$down"; return 1
}

# _fc_wake   Start the stopped host and wait until fc answers: about 35 s measured.
# Any controller may start it; starting a running one changes nothing.
_fc_wake() {
  local end=$(( $(date +%s) + ${FXA_FC_WAKE_SECONDS:-150} ))
  echo "Starting the runner host..."
  local err
  err="$(_gce compute instances start "$FXA_FC_INSTANCE" --zone "$FXA_FC_ZONE" --quiet 2>&1 >/dev/null)" \
    || { echo "  The runner host did not start ($(printf '%s' "$err" | grep -v '^ *$' | tail -1)); using GCE." >&2; return 1; }
  while [ "$(date +%s)" -lt "$end" ]; do
    timeout 3 bash -c ": </dev/tcp/${FXA_FC_HOST}/22" 2>/dev/null && _fc_raw list >/dev/null 2>&1 \
      && { rm -f "${TMPDIR:-/tmp}/fxa-fc-down-${USER:-u}-${FXA_FC_HOST}"; return 0; }
    sleep 3
  done
  echo "  The runner host did not answer in ${FXA_FC_WAKE_SECONDS:-150}s; using GCE." >&2; return 1
}
# A runner created on GCE (it has a zone file) stays GCE, whatever its name: a
# session started before the spike was turned on must be deleted as an instance.
_fc_owns() {
  [ -f "${LOG_DIR}/$1.zone" ] && return 1
  case "$1" in ${FXA_FC_NAMES:-agent-*}) return 0 ;; *) return 1 ;; esac
}
_fc_slot_of() { _fc list | awk -F'\t' -v n="$(vm_name "$1")" '$2 == n { print $1 }'; }

# Keep the GCE versions under _gce_ names and dispatch on the runner name.
for _f in vm_exists vm_clone vm_start vm_is_running vm_stop vm_delete vm_list; do
  eval "$(declare -f "$_f" | sed "1s/^$_f /_gce_$_f /")"
  eval "$_f() { if _fc_owns \"\${1:-}\"; then _fc_$_f \"\$@\"; else _gce_$_f \"\$@\"; fi; }"
done
unset _f
# A new runner wakes a stopped host. One it cannot wake, or that finds every slot
# taken, is a GCE runner (its zone file keeps it GCE from then on).
vm_clone() {
  if _fc_owns "${1:-}" && { _fc_up || _fc_wake; }; then
    _fc_vm_clone "$@" && return 0
    echo "  No free slot on the runner host; using GCE." >&2
  fi
  _gce_vm_clone "$@"
}

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
  local name="$1" n="" list rc=0
  # A stopped host has no slots, so there is nothing to stop. Any other miss is an
  # error: a slot left behind keeps the host up (fc-idle-stop sees it in use).
  if _fc_up; then
    if list="$(_fc list)"; then
      n="$(printf '%s\n' "$list" | awk -F'\t' -v n="$(vm_name "$name")" '$2 == n { print $1 }')"
      [ -z "$n" ] || { echo "Stopping slot ${n} ($(vm_name "$name"))..."; _fc stop "$n" >/dev/null; } \
        || { echo "ERROR: could not stop slot ${n} on ${FXA_FC_HOST}" >&2; rc=1; }
    else echo "ERROR: could not list the slots on ${FXA_FC_HOST}" >&2; rc=1; fi
  elif [ "$(_gce compute instances describe "$FXA_FC_INSTANCE" --zone "$FXA_FC_ZONE" --format 'value(status)' 2>/dev/null)" = RUNNING ]; then
    echo "ERROR: the runner host ${FXA_FC_HOST} runs but did not answer; slot $(vm_name "$name") may be left" >&2; rc=1
  fi
  rm -f "${LOG_DIR}/${name}.ssh-ok"; _gce_ssh_forget "$name"
  return "$rc"
}
# The GCE list plus the slots, in the same name, status, age form; a slot row
# adds a fourth column, firecracker.
vm_list() {
  _gce_vm_list
  _fc list 2>/dev/null | awk -F'\t' '{ printf "%s\tRUNNING\t%s\tfirecracker\n", $2, $4 }' || true
}
