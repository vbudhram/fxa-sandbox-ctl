#!/bin/bash
# Run every lib/*.check.sh on this host (macOS) and in an Ubuntu 24.04
# container (the manager VM's OS). Prints only failures and a summary line.
#   test.sh            both
#   test.sh mac|linux  one of them
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
rc=0

run_here() {
  local f bad=0
  for f in lib/*.check.sh; do bash "$f" 2>&1 | grep -q '^FAIL' && { echo "FAIL mac: $f"; bash "$f" 2>&1 | grep '^FAIL' | head -3; bad=1; }; done
  for f in fxa-sandbox-ctl lib/*.sh templates/*.sh infra/gce/*.sh skills/*/*.sh; do bash -n "$f" 2>/dev/null || { echo "SYNTAX: $f"; bad=1; }; done
  [ "$bad" = 0 ] && echo "mac: all checks pass" || rc=1
}

run_linux() {
  command -v docker >/dev/null || { echo "linux: skipped, no docker"; return; }
  docker run --rm -v "$ROOT":/src:ro ubuntu:24.04 bash -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null && apt-get install -y -qq git jq curl python3 openssl perl rsync ca-certificates >/dev/null 2>&1
    git config --global user.email test@example.com; git config --global user.name test; git config --global init.defaultBranch main
    cp -r /src /work && cd /work; bad=0
    for f in lib/*.check.sh; do bash "$f" 2>&1 | grep -q "^FAIL" && { echo "FAIL linux: $f"; bash "$f" 2>&1 | grep "^FAIL" | head -3; bad=1; }; done
    [ "$bad" = 0 ] && echo "linux: all checks pass"; exit "$bad"' 2>&1 | tail -20 || rc=1
}

case "${1:-both}" in
  mac) run_here ;;
  linux) run_linux ;;
  *) run_here; run_linux ;;
esac
exit "$rc"
