#!/bin/bash
# devslot.sh: one warm Firecracker slot per profile, held for building its scripts.
# A dev slot is named dev-<profile>. It never falls back to GCE, no reap touches it
# (it has no launch meta), and the host stops it after 30 min with no sync or run
# (infra/firecracker/idle-stop.sh). Needs FXA_FC_HOST.

_devslot_name() {
  [[ "${1:-}" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || { echo "ERROR: profile must match ^[a-z0-9][a-z0-9-]{0,30}\$" >&2; return 1; }
  echo "dev-$1"
}
# The host's idle stop counts from the last touch.
_devslot_touch() { local n; n="$(_fc_slot_of "$1")" && [ -n "$n" ] && _fc touch "$n" >/dev/null; }

cmd_devslot() {
  [ -n "${FXA_FC_HOST:-}" ] || { echo "ERROR: devslot needs FXA_FC_HOST (the Firecracker host)" >&2; return 1; }
  local sub="${1:-}" name; shift || true
  [ "$sub" = list ] && { _fc_up && _fc list | awk -F'\t' '$2 ~ /-dev-/'; return 0; }
  name="$(_devslot_name "${1:-}")" || return 1; shift
  FXA_FC_NAMES='dev-*'
  case "$sub" in
    up)
      { _fc_up || _fc_wake; } || return 1
      if _fc_vm_exists "$name"; then _devslot_touch "$name"; echo "$name is up (slot $(_fc_slot_of "$name"))"
      else _fc_vm_clone "$name"; fi ;;
    down) _fc_vm_delete "$name" ;;
    reset) _fc_vm_delete "$name"; cmd_devslot up "${name#dev-}" ;;
    sync)
      # sync <profile> <guest dir>: a tar.gz on stdin, extracted as agent. Removed files stay.
      local dir="${1:-}" t
      [[ "$dir" == /* ]] || { echo "ERROR: sync needs an absolute guest dir" >&2; return 1; }
      # Read stdin first: the ssh in _fc_vm_exists reads it too.
      t="$(mktemp)"; cat > "$t"
      _fc_vm_exists "$name" || { rm -f "$t"; echo "ERROR: $name is not up; run devslot up first" >&2; return 1; }
      local rc=0; vm_put "$name" "$t" "$dir" || rc=$?; rm -f "$t"
      _devslot_touch "$name"; [ "$rc" = 0 ] && echo "synced to $dir"; return "$rc" ;;
    run)
      # run <profile> '<command>': as agent, with the time and the memory after.
      [ -n "${1:-}" ] || { echo "usage: devslot run <profile> '<command>'" >&2; return 1; }
      _fc_vm_exists "$name" || { echo "ERROR: $name is not up; run devslot up first" >&2; return 1; }
      _devslot_touch "$name"
      local t0 rc=0; t0="$(date +%s)"
      # sudo -i mangles newlines and quotes, so the script travels as base64.
      vm_exec_as_agent "$name" "echo $(printf '%s\n' "$*" | base64 | tr -d '\n') | base64 -d | bash" || rc=$?
      local mem; mem="$(vm_exec_as_agent "$name" "free -m" 2>/dev/null | awk '/^Mem:/ {print $3 " MB used, " $7 " MB available"}')" || true
      echo "── exit $rc after $(( $(date +%s) - t0 ))s · ${mem:-memory unknown}"
      _devslot_touch "$name"; return "$rc" ;;
    *) echo "usage: devslot up|down|reset|run|sync <profile> ... | devslot list" >&2; return 1 ;;
  esac
}
