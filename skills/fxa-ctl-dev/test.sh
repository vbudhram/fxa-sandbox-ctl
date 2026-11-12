#!/bin/bash
# Run every lib/*.check.sh and skills/*/*.check.sh on this host (macOS) and in an Ubuntu 24.04
# container (the manager VM's OS). Prints only failures and a summary line.
#   test.sh            both
#   test.sh mac|here   this host only (here: any OS, as vm.sh test runs it on the manager)
#   test.sh linux      the Ubuntu container only
#   test.sh changed [base]   this host only, only the checks for the files changed since base (origin/main):
#                      a changed check, and each check that names a changed file; a Python service's tests (dashboard/*.check.py too);
#                      the bot e2e when fake-ctl.sh changed (FXA_BOT_REPO, default ../fxa-agent-bot); dashboard-v2's npm
#                      typecheck, lint, test and build, and its dist against the build, when it changed. CI runs the full suite on push.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
rc=0
export FXA_DB="${TMPDIR:-/tmp}/fxa-test-no-store-$$.db"
export FXA_SESSION_DIR="${TMPDIR:-/tmp}/fxa-test-no-sessions-$$"  # a check that forgets its own never reaches real sessions
export FXA_SESSION_STORE_URI="" FXA_SESSION_BACKUP_URI="" FXA_DB_BACKUP_URI=""  # empty turns the bucket copies off
unset ANTHROPIC_BASE_URL ANTHROPIC_API_KEY  # a Claude Code session sets them; the checks assert their own
export FXA_TEAMS_DIR="${TMPDIR:-/tmp}/fxa-test-no-teams-$$"  # the real team records change what a check expects

# _tmo <cmd...>   FXA_CHECK_TIMEOUT=<s>: stop a command that hangs, with its whole process group (a child that
# keeps the output pipe open would keep the capture waiting), and exit 142. macOS has no timeout.
_tmo() {
  [ -n "${FXA_CHECK_TIMEOUT:-}" ] || { "$@"; return; }
  perl -e '$t = shift; $p = fork; if (!$p) { setpgrp(0, 0); exec @ARGV }
    $SIG{ALRM} = sub { kill "KILL", -$p; exit 142 }; alarm $t; waitpid($p, 0); exit($? & 127 ? 128 + ($? & 127) : $? >> 8)' "$FXA_CHECK_TIMEOUT" "$@"
}

# _gwpy   The python3 with the desktop gateway's packages: desktop-gateway/.venv of this tree or of the main
# worktree, else python3 when it has them; empty when none has them.
_gwpy() {
  local p main; main="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; main="${main%/.git}"
  for p in "$ROOT/desktop-gateway/.venv/bin/python3" "$main/desktop-gateway/.venv/bin/python3" python3; do
    "$p" -c 'import aiohttp, google.auth' 2>/dev/null && { echo "$p"; return; }
  done
}
GW_SKIP="desktop-gateway/check.py (to run it: python3 -m venv desktop-gateway/.venv && desktop-gateway/.venv/bin/pip install -r desktop-gateway/requirements.txt)"

# others   The pids of the other test.sh runs on this host. Runs in parallel share the CPU. Not this run's process
# group, and not its callers: the shell that started it has the test.sh path in its command too.
others() {
  local me p=$$ up=" $$ "; me="$(ps -o pgid= -p $$ | tr -d ' ')"
  while p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"; [ -n "$p" ] && [ "$p" -gt 1 ]; do up="$up$p "; done
  ps -A -o pgid=,pid=,command= | awk -v me="$me" -v up="$up" '$1 != me && !index(up, " " $2 " ") && /fxa-ctl-dev\/test\.sh/ && !/awk/ { print $2 }' | paste -sd, - || true
}
say_others() {
  local o; o="$(others)"
  [ -z "$o" ] || echo "note $HOST: other test.sh runs on this host (pids $o): this run takes longer, and a check with a time limit can fail" >&2
}

# check_one <file> <host>   Run once, then read the output: grep -q in a pipe stopped at the
# first FAIL, the check died of SIGPIPE, and pipefail hid the failure. A nonzero exit fails too.
check_one() {
  local out code=0
  out="$(_tmo bash "$1" 2>&1)" || code=$?
  [ "$code" != 142 ] || out="${out}
FAIL $1 did not finish in ${FXA_CHECK_TIMEOUT}s"
  # A pass whose check skipped itself (a missing tool, bash 3.2) says so: a silent skip read as a pass.
  if ! grep -q '^FAIL' <<< "$out" && [ "$code" = 0 ]; then
    local s; s="$(grep -m1 -iE '^skip' <<< "$out" | sed -E 's/^[sS][kK][iI][pP]:? *//' || true)"; [ -z "$s" ] || echo "skip $2: $1: $s"; return 0; fi
  echo "FAIL $2: $1"; { grep '^FAIL' <<< "$out" || printf '  exit %s: %s\n' "$code" "$(tail -2 <<< "$out" | tr '\n' ' ')"; } | head -3
  # FXA_CHECK_VERBOSE=1 (CI): the failed check's last 60 lines, so a runner-only failure shows its traceback.
  [ -z "${FXA_CHECK_VERBOSE:-}" ] || tail -60 <<< "$out" | sed 's/^/  | /'
  return 1
}

# run_pool <host> <check files...>   The checks at once, FXA_CHECK_JOBS (8) at a time, each with its own
# store and sessions folder; their output in file order. Returns 1 when one failed.
run_pool() {
  local host="$1" d f n bad=0; shift
  d="$(mktemp -d "${TMPDIR:-/tmp}/fxa-checks.XXXXXX")"
  export -f check_one _tmo
  # xargs stops starting checks when one is killed (exit 125): a check with no output never ran.
  printf '%s\n' "$@" | xargs -P "${FXA_CHECK_JOBS:-8}" -I{} bash -c \
    'n="$(printf %s "$1" | tr / _)"; s=$SECONDS; FXA_DB="$2/$n.db" FXA_SESSION_DIR="$2/$n.s" check_one "$1" "$3" > "$2/$n.out" 2>&1 || touch "$2/$n.bad"
     echo "$(( SECONDS - s ))s $1" > "$2/$n.t"
     [ -z "${FXA_CHECK_PROGRESS:-}" ] || echo "done $1" >&2' _ {} "$d" "$host" || bad=1
  for f in "$@"; do
    n="$(printf %s "$f" | tr / _)"
    if [ -e "$d/$n.out" ]; then cat "$d/$n.out"; else echo "FAIL $host: $f did not run"; bad=1; fi
    [ ! -e "$d/$n.bad" ] || bad=1
  done
  # The slowest checks set the wall time of a run: name them, so a check that got slow shows.
  [ "$#" -lt 5 ] || echo "$host: slowest: $(cat "$d"/*.t 2>/dev/null | sort -rn | head -5 | paste -sd, - | sed 's/,/, /g')"
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
      for t in infra/llm-proxy/proxy_test.py infra/mcp-gateway/gateway_test.py dashboard/*.check.py; do o="$(_tmo python3 "$t" 2>&1)" || { c=$?; echo "FAIL $HOST: $t$([ "$c" != 142 ] || echo " did not finish in ${FXA_CHECK_TIMEOUT}s")"; grep -E "^(FAIL|ERROR)[: ]" <<< "$o" | head -3 | sed "s/^/  /"
        [ -z "${FXA_CHECK_VERBOSE:-}" ] || grep -m1 -A25 '^Traceback' <<< "$o" | sed 's/^/  | /'; b=1; }; done
      # The desktop gateway's check needs its packages (desktop-gateway/requirements.txt); without them it is skipped, not passed.
      p="$(_gwpy)"
      if [ -n "$p" ]; then o="$("$p" desktop-gateway/check.py 2>&1)" || { echo "FAIL $HOST: desktop-gateway/check.py"; grep -E "^(FAIL|ERROR)[: ]" <<< "$o" | head -3 | sed "s/^/  /"; b=1; }
      else echo "skip $HOST: $GW_SKIP"; fi
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
  docker run --rm --platform "$plat" -v "$ROOT":/src:ro "$img" bash -c "$(declare -f _tmo check_one run_pool)"'
    git config --global user.email test@example.com; git config --global user.name test; git config --global init.defaultBranch main
    cp -r /src /work && cd /work; bad=0
    run_pool linux lib/*.check.sh skills/*/*.check.sh infra/*/*.check.sh || bad=1
    for t in infra/llm-proxy/proxy_test.py infra/mcp-gateway/gateway_test.py desktop-gateway/check.py dashboard/*.check.py; do o="$(_tmo python3 "$t" 2>&1)" || { echo "FAIL linux: $t"; grep -E "^(FAIL|ERROR)[: ]" <<< "$o" | head -3 | sed "s/^/  /"; bad=1; }; done
    [ "$bad" = 0 ] && echo "linux: all checks pass"; exit "$bad"' 2>&1 | tail -20 || rc=1
}

# run_changed <base>   The checks that name a file changed since base (committed, staged, unstaged or new).
run_changed() {
  local base="${1:-origin/main}" f b c n fn picked=() bad=0 py="" e2e="" v2=""
  local files; files="$( { git diff --name-only "$base"...HEAD; git diff --name-only HEAD; git ls-files -o --exclude-standard; } 2>/dev/null | sort -u)"
  [ -n "$files" ] || { echo "$HOST: no changed files since $base"; return; }
  local all; all="$(ls lib/*.check.sh skills/*/*.check.sh infra/*/*.check.sh 2>/dev/null)"
  local half; half=$(( $(wc -l <<< "$all") / 2 ))
  for f in $files; do
    [ -f "$f" ] || continue
    case "$f" in *.check.sh) picked+=("$f"); continue ;; esac
    # The v2 app has its own npm checks below; its file names (index.html, package.json) would pick unrelated checks.
    # The live fixtures are C1: the dashboard's Python checks replay them.
    case "$f" in dashboard-v2/*) v2=1; case "$f" in dashboard-v2/fixtures/live/*) py+=" $(echo dashboard/*.check.py)" ;; esac; continue ;; esac
    # The check named after the file's folder: lib/db/008-x.sql is lib/db.check.sh's.
    c="$(dirname "$(dirname "$f")")/$(basename "$(dirname "$f")").check.sh"; [ -f "$c" ] && picked+=("$c")
    # The text a check names the file by; a skill's check.sh by its folder too, since every check's own name ends in check.sh.
    n="${f##*/}"; [ "$n" != check.sh ] || n="${f#"${f%/*/*}"/}"
    case "$f" in *.sh|fxa-sandbox-ctl) bash -n "$f" 2>/dev/null || { echo "SYNTAX: $f"; bad=1; } ;; esac
    case "$f" in
      # A shell file: the checks named after it, and each check that names a function the diff changed.
      *.sh|fxa-sandbox-ctl)
        b="${f##*/}"; b="${b%.sh}"
        for c in $all; do case "${c##*/}" in "$b".check.sh|"$b"-*.check.sh) picked+=("$c") ;; esac; done
        # A check that reads the file as text (a grep of snapshot.sh) names it.
        for c in $(grep -lF -- "$n" $all 2>/dev/null); do picked+=("$c"); done
        for fn in $( { git diff -U0 "$base"...HEAD -- "$f"; git diff -U0 HEAD -- "$f"; } 2>/dev/null \
            | sed -n 's/^@@[^@]*@@ *\([A-Za-z_][A-Za-z0-9_]*\)() *{.*/\1/p; s/^[+-]\([A-Za-z_][A-Za-z0-9_]*\)() *{.*/\1/p' | sort -u); do
          # A name in most checks (fail, in dev-smoke.sh) is a common word there, not a use of this function.
          c="$(grep -lw -- "$fn" $all 2>/dev/null)"; [ "$(grep -c . <<< "$c")" -le "$half" ] || continue
          for c in $c; do picked+=("$c"); done
        done ;;
      # Any other file: each check that names its path or its file name; a Python module also by
      # its name, since a check loads it with "import server".
      *) for c in $(grep -lF -- "$n" $all 2>/dev/null); do picked+=("$c"); done
         case "$f" in *.py) b="$(basename "$f" .py)"
           for c in $(grep -lE -- "(import [A-Za-z0-9_, ]*|from )$b([^A-Za-z0-9_]|\$)" $all 2>/dev/null); do picked+=("$c"); done ;; esac ;;
    esac
    # The Python services have their own tests, outside the *.check.sh pool.
    case "$f" in
      infra/llm-proxy/*) py+=" infra/llm-proxy/proxy_test.py" ;;
      infra/mcp-gateway/*) py+=" infra/mcp-gateway/gateway_test.py" ;;
      desktop-gateway/*) py+=" desktop-gateway/check.py" ;;
      dashboard/*.py|lib/fxadb.py) py+=" $(echo dashboard/*.check.py)" ;;
      # The in-process stats must stay equal to the shell's: a change to the shell side runs the golden check.
      lib/snapshot.sh|lib/db.sh|lib/session.sh) py+=" dashboard/stats.check.py" ;;
      skills/fxa-ctl-dev/fake-ctl.sh) e2e=1 ;;
    esac
  done
  py="$(printf '%s\n' $py | sort -u)"
  [ ${#picked[@]} -gt 0 ] || [ -n "$py" ] || [ -n "$e2e" ] || [ -n "$v2" ] || { echo "$HOST: no check names the changed files; CI runs the full suite"; [ "$bad" = 0 ] || rc=1; return; }

  # Largest first, as a full run does: the slow ones start first.
  [ ${#picked[@]} -eq 0 ] || picked=($(ls -S $(printf '%s\n' "${picked[@]}" | sort -u)))
  echo "$HOST: ${#picked[@]} checks for the changed files"
  [ -z "${FXA_CHANGED_DRY:-}" ] || { printf '%s\n' ${picked[@]+"${picked[@]}"}; return; }
  [ ${#picked[@]} -eq 0 ] || run_pool "$HOST" "${picked[@]}" || bad=1
  for t in $py; do
    local p=python3
    if [ "$t" = desktop-gateway/check.py ]; then p="$(_gwpy)"; [ -n "$p" ] || { echo "skip $HOST: $GW_SKIP"; continue; }; fi
    o="$(_tmo "$p" "$t" 2>&1)" || { c=$?; echo "FAIL $HOST: $t$([ "$c" != 142 ] || echo " did not finish in ${FXA_CHECK_TIMEOUT}s")"; grep -E "^(FAIL|ERROR)[: ]" <<< "$o" | head -3 | sed "s/^/  /"; bad=1; }
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
  # Vite needs Node 20.19+; test.sh linux has the apt Node 18. The e2e needs Playwright's Chromium, so CI runs it.
  if [ -n "$v2" ]; then
    if ! node -e 'const [a, b] = process.versions.node.split(".").map(Number); process.exit(a > 20 || (a === 20 && b >= 19) ? 0 : 1)' 2>/dev/null; then
      echo "skip $HOST: dashboard-v2: skipped: needs Node 20.19+"
    else
      local log="${TMPDIR:-/tmp}/fxa-v2-$$.log" s=""
      echo "$HOST: dashboard-v2 changed: typecheck, lint, test, build"
      ( cd dashboard-v2 && { [ -d node_modules ] || npm ci --no-audit --no-fund; } && npm run -s typecheck && npm run -s lint && npm test -s && npm run -s build ) > "$log" 2>&1 \
        || { echo "FAIL $HOST: dashboard-v2 npm checks (log: $log)"; bad=1; }
      s="$(git status --porcelain -- dashboard-v2/dist)"
      [ -z "$s" ] || { echo "FAIL $HOST: dashboard-v2/dist is not the build: commit the new dist"; head -5 <<< "$s" | sed 's/^/  /'; bad=1; }
    fi
  fi
  [ "$bad" = 0 ] && echo "$HOST: the changed files' checks pass" || rc=1
}

case "${1:-both}" in
  mac|here) say_others; run_here ;;
  changed) say_others; run_changed "${2:-}" ;;
  linux) run_linux ;;
  # Both at once: the Ubuntu half prints after this host's.
  *) say_others; l="$(mktemp "${TMPDIR:-/tmp}/fxa-linux.XXXXXX")"; ( run_linux; exit "$rc" ) > "$l" 2>&1 & lp=$!
     run_here; wait "$lp" || rc=1; cat "$l"; rm -f "$l" ;;
esac
exit "$rc"
