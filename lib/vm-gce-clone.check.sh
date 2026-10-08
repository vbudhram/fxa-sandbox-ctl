#!/usr/bin/env bash
# Offline check for vm_clone: zones in order, a stockout moves on, then the fallback machine type.
#   bash lib/vm-gce-clone.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
here="$(cd "$(dirname "$0")" && pwd)"
# config.sh fixes LOG_DIR (readonly), so the functions come out of vm-gce.sh on their own.
LOG_DIR="$tmp/logs" FXA_GCE_ZONES="z-a z-b z-c" FXA_GCE_SSH_KEY="$tmp/key" FXA_GCE_MACHINE_TYPE=c4a-standard-4 FXA_GCE_MAX_RUN_SECONDS=5400
FXA_GCE_NETWORK=n FXA_GCE_IMAGE=fxa-dev-base _GCE_SSH_HOSTS="$tmp"; mkdir -p "$LOG_DIR"; echo k > "$tmp/key.pub"
# The pattern goes through a variable: bash 3.2 brace-expands it inside "$(...)".
for f in vm_clone _gce_capacity_error _gce_zone_order; do pat="/^${f}() {/,/^}/p"; eval "$(sed -n "$pat" "$here/vm-gce.sh")"; done
eval "$(grep '^_gce_disk_type()' "$here/vm-gce.sh")"
vm_exists() { return 1; }; vm_name() { echo "agent-$1"; }; _gce_ssh_host_entry() { :; }
calls="$tmp/calls"
# OUT: "<machine-type>@<zone>=<result>" lines; result ok, out (stockout) or none (not offered there).
_gce() {
  case "$2 $3" in "instances describe") return 1 ;; esac
  local mt="" zone="" disk="" a prev=""; for a in "$@"; do case "$prev" in --machine-type) mt="$a" ;; --zone) zone="$a" ;; --boot-disk-type) disk="$a" ;; esac; prev="$a"; done
  echo "$mt $zone $disk" >> "$calls"
  case "$(grep "^${mt}@${zone}=" "$tmp/out" | cut -d= -f2)" in
    ok) return 0 ;;
    out) echo "ZONE_RESOURCE_POOL_EXHAUSTED"; return 1 ;;
    none) echo "Invalid value for field 'resource.machineType': 'zones/${zone}/machineTypes/${mt}'"; return 1 ;;
  esac
}
errors_record() { echo "$2" >> "$tmp/errors"; }

printf '%s\n' c4a-standard-4@z-a=out c4a-standard-4@z-b=ok > "$tmp/out"; : > "$calls"
vm_clone r1 >/dev/null 2>&1
check "a stockout moves to the next zone" "c4a-standard-4 z-a hyperdisk-balanced|c4a-standard-4 z-b hyperdisk-balanced" "$(paste -sd'|' "$calls")"

printf '%s\n' c4a-standard-4@z-a=out c4a-standard-4@z-b=out c4a-standard-4@z-c=out t2a-standard-4@z-a=out t2a-standard-4@z-b=none t2a-standard-4@z-c=ok > "$tmp/out"; : > "$calls"; : > "$tmp/errors"
rm -f "$LOG_DIR/last-good-zone"; out="$(vm_clone r2 2>&1)"; rc=$?
check "every zone out: the fallback type, on a balanced PD" "0|t2a-standard-4 z-c pd-balanced" "$rc|$(tail -1 "$calls")"
check "the fallback says so" "1" "$(grep -c 'Created as t2a-standard-4' <<< "$out")"
check "the zone it landed in is kept" "z-c" "$(cat "$LOG_DIR/r2.zone")"
check "stockouts on the way to a runner are not errors" "" "$(paste -sd, "$tmp/errors")"

printf '%s\n' c4a-standard-4@z-a=out c4a-standard-4@z-b=out c4a-standard-4@z-c=out > "$tmp/out"; : > "$calls"; : > "$tmp/errors"
out="$(FXA_GCE_MACHINE_FALLBACK= vm_clone r3 2>&1)"; rc=$?
check "no fallback: fails after the zones, and says which types" "1|3|1" "$rc|$(wc -l < "$calls" | tr -d ' ')|$(grep -c 'stocked out for c4a-standard-4\.' <<< "$out")"
check "no runner at all: one capacity error" "all_zones_out" "$(paste -sd, "$tmp/errors")"
# The image build: c4a in every zone, then the Arm fallback with the disk type it takes.
( pat='/^vm_image_build() {/,/^}/p'; eval "$(sed -n "$pat" "$here/vm-gce.sh")"
  set -o pipefail; rm -f "$LOG_DIR/last-good-zone"  # as the controller runs it, and no zone first
  SANDBOX_ROOT="$tmp/root" FXA_GCE_PROJECT=p; mkdir -p "$SANDBOX_ROOT/packer"; vm_guide_build() { :; }; : > "$calls"
  packer() { case "$1" in init) return 0 ;; esac
    local a mt="" zone="" disk=""; for a in "$@"; do case "$a" in machine_type=*) mt="${a#*=}" ;; zone=*) zone="${a#*=}" ;; disk_type=*) disk="${a#*=}" ;; esac; done
    echo "$mt $zone $disk" >> "$calls"
    case "$mt" in c4a-*) echo "does not have enough resources available"; return 1 ;; *) return 0 ;; esac; }
  vm_image_build >/dev/null 2>&1; rc=$?
  check "image build: every zone on c4a, then t2a on pd-balanced" "0|c4a-highcpu-4 z-a hyperdisk-balanced,c4a-highcpu-4 z-b hyperdisk-balanced,c4a-highcpu-4 z-c hyperdisk-balanced,t2a-standard-4 z-a pd-balanced" \
    "$rc|$(paste -sd, "$calls")"
  exit "$fail" ) || fail=1
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
