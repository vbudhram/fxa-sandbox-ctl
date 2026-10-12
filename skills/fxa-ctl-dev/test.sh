#!/bin/bash
# Run every lib/*.check.sh and skills/*/*.check.sh on this host (macOS) and in an Ubuntu 24.04
# container (the manager VM's OS). Prints only failures and a summary line.
#   test.sh            both
#   test.sh mac|here   this host only (here: any OS, as vm.sh test runs it on the manager)
#   test.sh linux      the Ubuntu container only
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

# run_pool <host> <check files...>   The checks at once, FXA_CHECK_JOBS (8) at a time, each with its own
# store and sessions folder; their output in file order. Returns 1 when one failed.
run_pool() {
  local host="$1" d f n bad=0; shift
  d="$(mktemp -d "${TMPDIR:-/tmp}/fxa-checks.XXXXXX")"
  export -f check_one
  printf '%s\n' "$@" | xargs -P "${FXA_CHECK_JOBS:-8}" -I{} bash -c \
    'n="$(printf %s "$1" | tr / _)"; FXA_DB="$2/$n.db" FXA_SESSION_DIR="$2/$n.s" check_one "$1" "$3" > "$2/$n.out" 2>&1 || touch "$2/$n.bad"' _ {} "$d" "$host"
  for f in "$@"; do n="$(printf %s "$f" | tr / _)"; cat "$d/$n.out"; [ ! -e "$d/$n.bad" ] || bad=1; done
  rm -rf "$d"; return "$bad"
}

HOST="$( [ "$(uname -s)" = Darwin ] && echo mac || echo linux)"
run_here() {
  local f bad=0
  run_pool "$HOST" lib/*.check.sh skills/*/*.check.sh infra/*/*.check.sh || bad=1
  for f in fxa-sandbox-ctl lib/*.sh templates/*.sh infra/*/*.sh infra/firecracker/fc infra/answer/fxa-git-ro skills/*/*.sh; do bash -n "$f" 2>/dev/null || { echo "SYNTAX: $f"; bad=1; }; done
  for t in infra/llm-proxy/proxy_test.py infra/mcp-gateway/gateway_test.py; do python3 "$t" >/dev/null 2>&1 || { echo "FAIL $HOST: $t"; bad=1; }; done
  [ "$bad" = 0 ] && echo "$HOST: all checks pass" || rc=1
}

run_linux() {
  command -v docker >/dev/null || { echo "linux: skipped, no docker"; return; }
  docker run --rm -v "$ROOT":/src:ro ubuntu:24.04 bash -c "$(declare -f check_one run_pool)"'
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null && apt-get install -y -qq git jq curl python3 openssl perl rsync ca-certificates >/dev/null 2>&1
    git config --global user.email test@example.com; git config --global user.name test; git config --global init.defaultBranch main
    cp -r /src /work && cd /work; bad=0
    run_pool linux lib/*.check.sh skills/*/*.check.sh infra/*/*.check.sh || bad=1
    for t in infra/llm-proxy/proxy_test.py infra/mcp-gateway/gateway_test.py; do python3 "$t" >/dev/null 2>&1 || { echo "FAIL linux: $t"; bad=1; }; done
    [ "$bad" = 0 ] && echo "linux: all checks pass"; exit "$bad"' 2>&1 | tail -20 || rc=1
}

case "${1:-both}" in
  mac|here) run_here ;;
  linux) run_linux ;;
  # Both at once: the Ubuntu half prints after this host's.
  *) l="$(mktemp "${TMPDIR:-/tmp}/fxa-linux.XXXXXX")"; ( run_linux; exit "$rc" ) > "$l" 2>&1 & lp=$!
     run_here; wait "$lp" || rc=1; cat "$l"; rm -f "$l" ;;
esac
exit "$rc"
