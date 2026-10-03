#!/bin/bash
# Run every lib/*.check.sh and skills/*/*.check.sh on this host (macOS) and in an Ubuntu 24.04
# container (the manager VM's OS). Prints only failures and a summary line.
#   test.sh            both
#   test.sh mac|linux  one of them
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
rc=0
export FXA_DB="${TMPDIR:-/tmp}/fxa-test-no-store-$$.db"
export FXA_SESSION_DIR="${TMPDIR:-/tmp}/fxa-test-no-sessions-$$"  # a check that forgets its own never reaches real sessions
export FXA_SESSION_STORE_URI="" FXA_SESSION_BACKUP_URI="" FXA_DB_BACKUP_URI=""  # empty turns the bucket copies off

# check_one <file> <host>   Run once, then read the output: grep -q in a pipe stopped at the
# first FAIL, the check died of SIGPIPE, and pipefail hid the failure. A nonzero exit fails too.
check_one() {
  local out code=0; out="$(bash "$1" 2>&1)" || code=$?
  if ! grep -q '^FAIL' <<< "$out" && [ "$code" = 0 ]; then return 0; fi
  echo "FAIL $2: $1"; { grep '^FAIL' <<< "$out" || printf '  exit %s: %s\n' "$code" "$(tail -2 <<< "$out" | tr '\n' ' ')"; } | head -3
  return 1
}

run_here() {
  local f bad=0
  for f in lib/*.check.sh skills/*/*.check.sh infra/*/*.check.sh; do check_one "$f" mac || bad=1; done
  for f in fxa-sandbox-ctl lib/*.sh templates/*.sh infra/gce/*.sh skills/*/*.sh; do bash -n "$f" 2>/dev/null || { echo "SYNTAX: $f"; bad=1; }; done
  python3 infra/llm-proxy/proxy_test.py >/dev/null 2>&1 || { echo "FAIL mac: infra/llm-proxy/proxy_test.py"; bad=1; }
  [ "$bad" = 0 ] && echo "mac: all checks pass" || rc=1
}

run_linux() {
  command -v docker >/dev/null || { echo "linux: skipped, no docker"; return; }
  docker run --rm -v "$ROOT":/src:ro ubuntu:24.04 bash -c "$(declare -f check_one)"'
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null && apt-get install -y -qq git jq curl python3 openssl perl rsync ca-certificates >/dev/null 2>&1
    git config --global user.email test@example.com; git config --global user.name test; git config --global init.defaultBranch main
    cp -r /src /work && cd /work; bad=0
    for f in lib/*.check.sh skills/*/*.check.sh infra/*/*.check.sh; do check_one "$f" linux || bad=1; done
    python3 infra/llm-proxy/proxy_test.py >/dev/null 2>&1 || { echo "FAIL linux: infra/llm-proxy/proxy_test.py"; bad=1; }
    [ "$bad" = 0 ] && echo "linux: all checks pass"; exit "$bad"' 2>&1 | tail -20 || rc=1
}

case "${1:-both}" in
  mac) run_here ;;
  linux) run_linux ;;
  *) run_here; run_linux ;;
esac
exit "$rc"
