#!/bin/bash
# vm.sh — VM naming and backend selection. The lifecycle lives in lib/vm-<backend>.sh.

# Source config if not already loaded
if [ -z "${FXA_IMAGE_NAME:-}" ]; then
  source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
fi

# ── VM naming ──────────────────────────────────────────────────

vm_name() {
  local name="$1"
  echo "${VM_PREFIX}-${name}"
}

# ── Backend selection ──────────────────────────────────────────

# vm_backend_load
#   Resolve FXA_VM_BACKEND once and source the backend. Runs after flag parsing,
#   like runtime_load, because --backend arrives after vm.sh is sourced.
vm_backend_load() {
  [ -n "${_FXA_VM_BACKEND_LOADED:-}" ] && return 0
  local backend="${FXA_VM_BACKEND:-${PIPE_VM_BACKEND:-tart}}"
  case "$backend" in
    tart|gce) ;;
    *) echo "ERROR: FXA_VM_BACKEND='${backend}' is not tart or gce." >&2; return 1 ;;
  esac
  # shellcheck source=/dev/null
  source "$(dirname "${BASH_SOURCE[0]}")/vm-${backend}.sh" || return 1
  FXA_VM_BACKEND="$backend"
  _FXA_VM_BACKEND_LOADED=1
}
