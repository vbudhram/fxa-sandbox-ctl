#!/usr/bin/env bash
# devslot.sh: build a team profile's guest scripts against a warm Firecracker slot,
# from the laptop. Each call goes through the manager (lib/devslot.sh).
#   devslot.sh up|down|reset <profile>        claim, drop, or restore a clean slot
#   devslot.sh sync <profile> <guest dir>=<local dir>...   copy git-tracked and new files
#                                              (not ignored ones); removed files stay
#   devslot.sh run <profile> '<command>'      run as agent; prints exit, time and memory
#   devslot.sh run <profile> - < script.sh    the same, with a local script
#   devslot.sh list
# FXA_FC_HOST: the Firecracker host's address (required).
set -euo pipefail
H="$(cd "$(dirname "$0")/../fxa-manager" && pwd)/vm.sh"
: "${FXA_FC_HOST:?set FXA_FC_HOST to the Firecracker host address}"
# vm.sh run drops the remote stderr, so it comes back on stdout.
ctl() { printf 'FXA_FC_HOST=%q ./fxa-sandbox-ctl --backend gce devslot%s 2>&1\n' "$FXA_FC_HOST" "$(printf ' %q' "$@")"; }
sub="${1:-}"; shift || true
case "$sub" in
  up|down|reset|list) ctl "$sub" "$@" | bash "$H" run - ;;
  run)
    [ $# -eq 2 ] || { echo "usage: devslot.sh run <profile> '<command>' | -" >&2; exit 1; }
    cmd="$2"; [ "$cmd" = - ] && cmd="$(cat)"
    ctl run "$1" "$cmd" | bash "$H" run - ;;
  sync)
    p="${1:?profile}"; shift
    [ $# -gt 0 ] || { echo "usage: devslot.sh sync <profile> <guest dir>=<local dir>..." >&2; exit 1; }
    for pair in "$@"; do
      g="${pair%%=*}" l="${pair#*=}"; [ -d "$l" ] || { echo "ERROR: $l is not a directory" >&2; exit 1; }
      t0=$(date +%s)
      { printf 'base64 -d <<"B64" | %s\n' "$(ctl sync "$p" "$g")"
        ( cd "$l" && { git ls-files -co --exclude-standard 2>/dev/null || find . -type f; } \
          | while IFS= read -r f; do [ -f "$f" ] && printf '%s\n' "$f"; done | COPYFILE_DISABLE=1 tar -czf - -T - ) | base64
        echo B64; } | bash "$H" run -
      echo "  $l -> $g ($(( $(date +%s) - t0 ))s)"
    done ;;
  *) sed -n '2,10p' "$0" >&2; exit 1 ;;
esac
