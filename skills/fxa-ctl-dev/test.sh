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
  # xargs stops starting checks when one is killed (exit 125): a check with no output never ran.
  printf '%s\n' "$@" | xargs -P "${FXA_CHECK_JOBS:-8}" -I{} bash -c \
    'n="$(printf %s "$1" | tr / _)"; FXA_DB="$2/$n.db" FXA_SESSION_DIR="$2/$n.s" check_one "$1" "$3" > "$2/$n.out" 2>&1 || touch "$2/$n.bad"' _ {} "$d" "$host" || bad=1
  for f in "$@"; do
    n="$(printf %s "$f" | tr / _)"
    if [ -e "$d/$n.out" ]; then cat "$d/$n.out"; else echo "FAIL $host: $f did not run"; bad=1; fi
    [ ! -e "$d/$n.bad" ] || bad=1
  done
  rm -rf "$d"; return "$bad"
}

HOST="$( [ "$(uname -s)" = Darwin ] && echo mac || echo linux)"
run_here() {
  local f bad=0 k=0 picked=() sh="${FXA_CHECK_SHARD:-1/1}"
  # FXA_CHECK_SHARD=i/n: CI's jobs each run every n-th check; the first also runs the syntax checks, the last the Python ones.
  local i="${sh%/*}" n="${sh#*/}"
  # Largest first (a rough measure of time): the slow ones spread across the jobs and start first in each.
  for f in $(ls -S lib/*.check.sh skills/*/*.check.sh infra/*/*.check.sh); do [ $(( k++ % n )) -eq $(( i - 1 )) ] && picked+=("$f"); done
  # The Python tests run beside the pool: the proxy's alone takes 14 s.
  local py="" pyp=""
  if [ "$i" = "$n" ]; then
    py="$(mktemp "${TMPDIR:-/tmp}/fxa-py.XXXXXX")"
    ( b=0
      for t in infra/llm-proxy/proxy_test.py infra/mcp-gateway/gateway_test.py; do python3 "$t" >/dev/null 2>&1 || { echo "FAIL $HOST: $t"; b=1; }; done
      # The desktop gateway's check needs its packages (desktop-gateway/requirements.txt); without them it is skipped, not passed.
      if python3 -c 'import aiohttp, google.auth' 2>/dev/null; then python3 desktop-gateway/check.py >/dev/null 2>&1 || { echo "FAIL $HOST: desktop-gateway/check.py"; b=1; }
      else echo "skip $HOST: desktop-gateway/check.py (pip install -r desktop-gateway/requirements.txt to run it)"; fi
      exit "$b" ) > "$py" 2>&1 & pyp=$!
  fi
  run_pool "$HOST" "${picked[@]}" || bad=1
  if [ "$i" = 1 ]; then
    for f in fxa-sandbox-ctl lib/*.sh templates/*.sh infra/*/*.sh infra/firecracker/fc infra/answer/fxa-git-ro skills/*/*.sh profiles/*/boot.sh profiles/*/skills/*/*.sh; do bash -n "$f" 2>/dev/null || { echo "SYNTAX: $f"; bad=1; }; done
  fi
  if [ -n "$py" ]; then wait "$pyp" || bad=1; cat "$py"; rm -f "$py"; fi
  [ "$bad" = 0 ] && echo "$HOST: all checks pass" || rc=1
}

run_linux() {
  command -v docker >/dev/null || { echo "linux: skipped, no docker"; return; }
  # The host's own platform (no emulation on an arm64 Mac), and an image with the packages that
  # docker builds once and then takes from its cache, so a run does not reinstall them.
  local plat=linux/amd64 img=fxa-sandbox-ctl-test:2
  case "$(uname -m)" in arm64|aarch64) plat=linux/arm64 ;; esac
  printf '%s\n' 'FROM ubuntu:24.04' 'ENV DEBIAN_FRONTEND=noninteractive' \
    'RUN apt-get update -qq && apt-get install -y -qq git jq curl python3 python3-pip openssl perl rsync ca-certificates >/dev/null && rm -rf /var/lib/apt/lists/*' \
    "RUN pip3 install -q --break-system-packages $(tr '\n' ' ' < "$ROOT/desktop-gateway/requirements.txt")" \
    | docker build -q --platform "$plat" -t "$img" - >/dev/null || { echo "linux: the test image did not build"; rc=1; return; }
  docker run --rm --platform "$plat" -v "$ROOT":/src:ro "$img" bash -c "$(declare -f check_one run_pool)"'
    git config --global user.email test@example.com; git config --global user.name test; git config --global init.defaultBranch main
    cp -r /src /work && cd /work; bad=0
    run_pool linux lib/*.check.sh skills/*/*.check.sh infra/*/*.check.sh || bad=1
    for t in infra/llm-proxy/proxy_test.py infra/mcp-gateway/gateway_test.py desktop-gateway/check.py; do python3 "$t" >/dev/null 2>&1 || { echo "FAIL linux: $t"; bad=1; }; done
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
