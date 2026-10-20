#!/bin/bash
# Run every lib/*.check.sh and skills/*/*.check.sh on this host (macOS) and in an Ubuntu 24.04
# container (the manager VM's OS). Prints only failures and a summary line.
#   test.sh            both
#   test.sh mac|here   this host only (here: any OS, as vm.sh test runs it on the manager)
#   test.sh linux      the Ubuntu container only
#   test.sh changed [base]   this host only, only the checks for the files changed since base (origin/main):
#                      a changed check, and each check that names a changed file; a Python service's tests;
#                      the bot e2e when fake-ctl.sh changed (FXA_BOT_REPO, default ../fxa-agent-bot). CI runs the full suite on push.
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
  # A pass whose check skipped itself (a missing tool, bash 3.2) says so: a silent skip read as a pass.
  if ! grep -q '^FAIL' <<< "$out" && [ "$code" = 0 ]; then
    local s; s="$(grep -m1 -iE '^skip' <<< "$out" | sed -E 's/^[sS][kK][iI][pP]:? *//' || true)"; [ -z "$s" ] || echo "skip $2: $1: $s"; return 0; fi
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
      for t in infra/llm-proxy/proxy_test.py infra/mcp-gateway/gateway_test.py; do o="$(python3 "$t" 2>&1)" || { echo "FAIL $HOST: $t"; grep -E "^(FAIL|ERROR)[: ]" <<< "$o" | head -3 | sed "s/^/  /"; b=1; }; done
      # The desktop gateway's check needs its packages (desktop-gateway/requirements.txt); without them it is skipped, not passed.
      if python3 -c 'import aiohttp, google.auth' 2>/dev/null; then o="$(python3 desktop-gateway/check.py 2>&1)" || { echo "FAIL $HOST: desktop-gateway/check.py"; grep -E "^(FAIL|ERROR)[: ]" <<< "$o" | head -3 | sed "s/^/  /"; b=1; }
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
  local plat=linux/amd64 img=fxa-sandbox-ctl-test:5
  case "$(uname -m)" in arm64|aarch64) plat=linux/arm64 ;; esac
  printf '%s\n' 'FROM ubuntu:24.04' 'ENV DEBIAN_FRONTEND=noninteractive' \
    'RUN apt-get update -qq && apt-get install -y -qq git jq curl python3 python3-pip openssl perl rsync sqlite3 ca-certificates nodejs npm ffmpeg >/dev/null && rm -rf /var/lib/apt/lists/*' \
    "RUN pip3 install -q --break-system-packages $(tr '\n' ' ' < "$ROOT/desktop-gateway/requirements.txt")" \
    | docker build -q --platform "$plat" -t "$img" - >/dev/null || { echo "linux: the test image did not build"; rc=1; return; }
  docker run --rm --platform "$plat" -v "$ROOT":/src:ro "$img" bash -c "$(declare -f check_one run_pool)"'
    git config --global user.email test@example.com; git config --global user.name test; git config --global init.defaultBranch main
    cp -r /src /work && cd /work; bad=0
    run_pool linux lib/*.check.sh skills/*/*.check.sh infra/*/*.check.sh || bad=1
    for t in infra/llm-proxy/proxy_test.py infra/mcp-gateway/gateway_test.py desktop-gateway/check.py; do o="$(python3 "$t" 2>&1)" || { echo "FAIL linux: $t"; grep -E "^(FAIL|ERROR)[: ]" <<< "$o" | head -3 | sed "s/^/  /"; bad=1; }; done
    [ "$bad" = 0 ] && echo "linux: all checks pass"; exit "$bad"' 2>&1 | tail -20 || rc=1
}

# run_changed <base>   The checks that name a file changed since base (committed, staged, unstaged or new).
run_changed() {
  local base="${1:-origin/main}" f b c picked=() bad=0 py="" e2e=""
  local files; files="$( { git diff --name-only "$base"...HEAD; git diff --name-only HEAD; git ls-files -o --exclude-standard; } 2>/dev/null | sort -u)"
  [ -n "$files" ] || { echo "$HOST: no changed files since $base"; return; }
  local all; all="$(ls lib/*.check.sh skills/*/*.check.sh infra/*/*.check.sh 2>/dev/null)"
  for f in $files; do
    [ -f "$f" ] || continue
    case "$f" in *.check.sh) picked+=("$f"); continue ;; esac
    # The check named after the file's folder: lib/db/008-x.sql is lib/db.check.sh's.
    c="$(dirname "$(dirname "$f")")/$(basename "$(dirname "$f")").check.sh"; [ -f "$c" ] && picked+=("$c")
    case "$f" in *.sh|fxa-sandbox-ctl) bash -n "$f" 2>/dev/null || { echo "SYNTAX: $f"; bad=1; } ;; esac
    case "$f" in
      # A shell file: the checks named after it, and each check that names a function the diff changed.
      *.sh|fxa-sandbox-ctl)
        b="$(basename "$f" .sh)"
        for c in $all; do case "$(basename "$c")" in "$b".check.sh|"$b"-*.check.sh) picked+=("$c") ;; esac; done
        # A check that reads the file as text (a grep of snapshot.sh) names it.
        for c in $(grep -lF -- "$(basename "$f")" $all 2>/dev/null); do picked+=("$c"); done
        for fn in $( { git diff -U0 "$base"...HEAD -- "$f"; git diff -U0 HEAD -- "$f"; } 2>/dev/null \
            | sed -n 's/^@@[^@]*@@ *\([A-Za-z_][A-Za-z0-9_]*\)() *{.*/\1/p; s/^[+-]\([A-Za-z_][A-Za-z0-9_]*\)() *{.*/\1/p' | sort -u); do
          for c in $(grep -lw -- "$fn" $all 2>/dev/null); do picked+=("$c"); done
        done ;;
      # Any other file: each check that names its path or its file name; a Python module also by
      # its name, since a check loads it with "import server".
      *) for c in $(grep -lF -- "$(basename "$f")" $all 2>/dev/null); do picked+=("$c"); done
         case "$f" in *.py) b="$(basename "$f" .py)"
           for c in $(grep -lE -- "(import [A-Za-z0-9_, ]*|from )$b([^A-Za-z0-9_]|\$)" $all 2>/dev/null); do picked+=("$c"); done ;; esac ;;
    esac
    # The Python services have their own tests, outside the *.check.sh pool.
    case "$f" in
      infra/llm-proxy/*) py+=" infra/llm-proxy/proxy_test.py" ;;
      infra/mcp-gateway/*) py+=" infra/mcp-gateway/gateway_test.py" ;;
      desktop-gateway/*) py+=" desktop-gateway/check.py" ;;
      skills/fxa-ctl-dev/fake-ctl.sh) e2e=1 ;;
    esac
  done
  py="$(printf '%s\n' $py | sort -u)"
  [ ${#picked[@]} -gt 0 ] || [ -n "$py" ] || [ -n "$e2e" ] || { echo "$HOST: no check names the changed files; CI runs the full suite"; [ "$bad" = 0 ] || rc=1; return; }
  [ ${#picked[@]} -eq 0 ] || picked=($(printf '%s\n' "${picked[@]}" | sort -u))
  echo "$HOST: ${#picked[@]} checks for the changed files"
  [ ${#picked[@]} -eq 0 ] || run_pool "$HOST" "${picked[@]}" || bad=1
  for t in $py; do
    if [ "$t" = desktop-gateway/check.py ] && ! python3 -c 'import aiohttp, google.auth' 2>/dev/null; then
      echo "skip $HOST: $t (pip install -r desktop-gateway/requirements.txt to run it)"; continue; fi
    o="$(python3 "$t" 2>&1)" || { echo "FAIL $HOST: $t"; grep -E "^(FAIL|ERROR)[: ]" <<< "$o" | head -3 | sed "s/^/  /"; bad=1; }
  done
  # The bot's e2e plays every scenario against fake-ctl.sh; a ctl push to main does not run it.
  if [ -n "$e2e" ]; then
    local bot="${FXA_BOT_REPO:-$ROOT/../fxa-agent-bot}"
    if [ -f "$bot/package.json" ]; then
      echo "$HOST: fake-ctl.sh changed: the bot e2e in $bot"
      ( cd "$bot" && FXA_CTL_REPO="$ROOT" npm run -s e2e ) > "${TMPDIR:-/tmp}/fxa-e2e-$$.log" 2>&1 \
        || { echo "FAIL $HOST: the bot e2e (log: ${TMPDIR:-/tmp}/fxa-e2e-$$.log)"; bad=1; }
    else echo "skip $HOST: the bot e2e (no bot tree at $bot; set FXA_BOT_REPO)"; fi
  fi
  [ "$bad" = 0 ] && echo "$HOST: the changed files' checks pass" || rc=1
}

case "${1:-both}" in
  mac|here) run_here ;;
  changed) run_changed "${2:-}" ;;
  linux) run_linux ;;
  # Both at once: the Ubuntu half prints after this host's.
  *) l="$(mktemp "${TMPDIR:-/tmp}/fxa-linux.XXXXXX")"; ( run_linux; exit "$rc" ) > "$l" 2>&1 & lp=$!
     run_here; wait "$lp" || rc=1; cat "$l"; rm -f "$l" ;;
esac
exit "$rc"
