#!/usr/bin/env bash
# Plan, then run, the fastest correct checks for the changed files. See SKILL.md.
#   verify.sh [--run] [--no-types] [--no-lint] [--plan <test-plan.json>] [file...]
#   verify.sh --revert [test file...]   the tests fail without the fix, pass with it
#   verify.sh --failed   rerun only the rows that failed or ran nothing last time
#   verify.sh --stale    as --failed, plus the rows of each file changed after the last verdict
#   verify.sh --bg <the options above>   start that run in the background
#   verify.sh wait [seconds]   wait for it (270 s by default, under the cache's 5 min): its verdict,
#                              "still running" (exit 75), or that it died (exit 4)
# With no files: the working diff against origin/main, untracked files included.
# With --plan: the specs the test plan names (see /fxa-test-plan) first, then the
# related specs of the changed files as a safety net, then any functional spec.
set -u
job="${FXA_VERIFY_JOB_DIR:-${FXA_WORKSPACE:-/workspace}/.fxa-verify-job}"
running() { [ -f "${job}/pid" ] && [ ! -f "${job}/rc" ] && kill -0 "$(cat "${job}/pid")" 2>/dev/null; }
if [ "${1:-}" = --bg ]; then
  shift; running && { echo "a background run is still going; use: bash $0 wait" >&2; exit 2; }
  rm -rf "$job"; mkdir -p "$job"
  # The exit code goes to a file, so wait tells a finished run from a dead one; setsid outlives the Bash call.
  nohup $(command -v setsid) bash -c 'bash "$0" "$@" > "'"$job"'/log" 2>&1; echo $? > "'"$job"'/rc"' "$0" "$@" </dev/null >/dev/null 2>&1 &
  echo $! > "${job}/pid"; date +%s > "${job}/started"
  echo "started in the background. Wait for it with: bash $0 wait"
  exit 0
fi
if [ "${1:-}" = wait ]; then
  [ -f "${job}/pid" ] || { echo "no background run; start one with: bash $0 --bg --run ..." >&2; exit 2; }
  limit="${2:-270}"; t0=$(date +%s)
  while running && [ $(( $(date +%s) - t0 )) -lt "$limit" ]; do sleep "${FXA_VERIFY_POLL_S:-5}"; done
  ran=$(( $(date +%s) - $(cat "${job}/started" 2>/dev/null || echo "$t0") ))
  if [ -f "${job}/rc" ]; then tail -40 "${job}/log"; exit "$(cat "${job}/rc")"; fi
  if running; then echo "still running after ${ran}s. Last line: $(tail -1 "${job}/log" | cut -c1-200). Call: bash $0 wait"; exit 75; fi
  echo "the run died after ${ran}s without a verdict. Last lines:"; tail -5 "${job}/log"; exit 4
fi
cd "${FXA_WORKSPACE:-/workspace}" || exit 2
RUN=0 TYPES=1 LINT=1 MAX_RELATED=15 REVERT=0 FAILED=0 STALE=0
files=() PLAN=""
while [ $# -gt 0 ]; do
  case "$1" in --run) RUN=1 ;; --types) TYPES=1 ;; --no-types) TYPES=0 ;; --no-lint) LINT=0 ;; --plan) PLAN="${2:?--plan needs a file}"; shift ;; --revert) REVERT=1 ;; --failed) FAILED=1 ;; --stale) STALE=1 ;; *) files+=("$1") ;; esac
  shift
done
given=${#files[@]} VSTART=$(date +%s)
if [ "${#files[@]}" -eq 0 ]; then
  base="$(git merge-base HEAD origin/main 2>/dev/null || echo HEAD)"
  mapfile -t files < <({ git diff --name-only --diff-filter=d "$base"; git ls-files -o --exclude-standard; } \
    | grep -vE '^(\.fxa-|ai/|artifacts/)' | sort -u)
fi
[ "${#files[@]}" -gt 0 ] || [ -n "$PLAN" ] || { echo "No changed files."; exit 0; }
export NODE_OPTIONS="--max-old-space-size=4096 ${NODE_OPTIONS:-}"
# Two runs at once share the log dir and the tree. Fd 9 holds the lock; each command
# closes it (9>&-), so a daemon that a row starts cannot keep the lock.
if [ "$RUN$REVERT$FAILED$STALE" != 0000 ] && command -v flock >/dev/null; then
  lockf="${TMPDIR:-/tmp}/fxa-verify-$(id -u).lock"; exec 9>"$lockf"
  flock -n 9 || { echo "ERROR: another fxa-verify run holds $lockf. Wait for it to end, then run again."; exit 75; }
fi
# The run's start time, moved to START with the verdict: a file edited during the run counts as changed after it.
START=/workspace/.fxa-verify-start
[ "$RUN$FAILED$STALE" != 000 ] && touch "$START.tmp"
is_test() { case "$1" in *.spec.*|*.test.*|*/test/*|*/tests/*|*/__tests__/*|*/__mocks__/*|*/__snapshots__/*|packages/functional-tests/*) return 0 ;; esac; return 1; }

# The project that owns a file: the nearest dir up with project.json or package.json.
owner() {
  local d; d="$(dirname "$1")"
  while [ "$d" != "." ] && [ "$d" != "/" ]; do
    [ -f "$d/project.json" ] || [ -f "$d/package.json" ] && { echo "$d"; return; }
    d="$(dirname "$d")"
  done
  echo "."
}
nearest_jest() { # nearest jest.config.* at or above a dir, within the project
  local d="$1"; while [ "$d" != "." ]; do
    for c in jest.config.ts jest.config.js; do [ -f "$d/$c" ] && { echo "$d/$c"; return; }; done
    d="$(dirname "$d")"; done
}

# tsc_files <tsconfig> <file...>   Fail only on type errors in these files, for a
# project whose tsc already fails on main in the VM (CI builds what it imports).
# ponytail: an error the change causes in an unchanged file is missed; CI's compile catches it.
tsc_files() {
  local cfg="$1" f out bad=""; shift
  out="$(npx tsc --noEmit -p "$cfg" 2>&1)"
  for f in "$@"; do bad+="$(awk -v f="$f(" 'index($0, f) == 1' <<<"$out")"; done
  if [ -z "$bad" ]; then echo "no type errors in the changed files ($(grep -c 'error TS' <<<"$out") in other files, as on main)"; return 0; fi
  printf '%s\n' "$bad"; return 1
}

plan=() # "label|dir|command"
add() { plan+=("$1|$2|$3"); }
rel() { local p="$1"; shift; local out=(); for f in "$@"; do out+=("${f#"$p"/}"); done; printf '%q ' "${out[@]}"; }

# fmt_files <file...>   The format row: write Prettier on the files and name them. A file main has
# unformatted stays as it is, since a full reformat buries a small edit. Exit 2: Prettier cannot parse one.
fmt_files() {
  local f="" rc=0 b="" x="" k=()
  f="$(npx prettier --list-different --ignore-unknown "$@")"; rc=$?; [ "$rc" -le 1 ] || return "$rc"
  b="$(git merge-base HEAD origin/main 2>/dev/null || true)"
  for x in $f; do
    if [ -n "$b" ] && git cat-file -e "$b:./$x" 2>/dev/null && ! git show "$b:./$x" | npx prettier --check --stdin-filepath "$x" >/dev/null 2>&1; then
      echo "left as on main, which Prettier does not pass: $x"; continue
    fi
    k+=("$x")
  done
  [ "${#k[@]}" -eq 0 ] || { npx prettier --write --ignore-unknown "${k[@]}" >/dev/null && echo "formatted: ${k[*]}"; }
}

# plan_files <label prefix> <file...>   One command per owning project for these files.
plan_files() {
  local pre="$1"; shift
  local -A byproj=()
  local f p
  for f in "$@"; do [ -e "$f" ] || continue; p="$(owner "$f")"; byproj[$p]+="$f "; done

for p in $(printf '%s\n' "${!byproj[@]}" | sort); do
  read -r -a fs <<<"${byproj[$p]}"
  code=(); for f in "${fs[@]}"; do case "$f" in *.ts|*.tsx|*.js|*.jsx|*.mjs) code+=("$f") ;; esac; done
  [ "${#code[@]}" -gt 0 ] || { add "${pre}$p" "." "echo 'no code changed (docs, config, or l10n only)'"; continue; }
  r="$(rel "$p" "${code[@]}")"
  case "$p" in
    packages/fxa-settings)
      add "${pre}$p tests" "$p" "CI=true SKIP_PREFLIGHT_CHECK=true node scripts/test.js --watchAll=false --findRelatedTests $r" ;;
    packages/fxa-auth-server)
      # Jest defaults to CPUs - 1 = 3 workers here; the whole unit project then left
      # 0.2 GB free. Two workers; oauth-api one, as in CI (its specs share a DB).
      # Four Jest projects; integration ignores oauth_api and test/scripts, which
      # have projects of their own, so each file goes to the one that runs it.
      unit=(); integ=(); scr=(); oapi=()
      for f in "${code[@]}"; do case "$f" in
        */test/scripts/*.in.spec.ts) scr+=("$f") ;;
        */oauth_api.in.spec.ts) oapi+=("$f") ;;
        *.in.spec.ts) integ+=("$f") ;;
        *) unit+=("$f") ;; esac; done
      # agent-env.sh sets SNS_TOPIC_ENDPOINT for the goaws stub; the prod config
      # specs reject it outside dev, so unit runs go without it.
      [ "${#unit[@]}" -gt 0 ] && add "${pre}$p unit" "$p" "env -u SNS_TOPIC_ENDPOINT yarn test --maxWorkers=2 --findRelatedTests $(rel "$p" "${unit[@]}")"
      # The fxa DB has no tables until the patcher runs (fxa-start runs it); without
      # it the suite waits 63 s and fails on ER_NO_SUCH_TABLE. It is fast and idempotent.
      [ "$(( ${#integ[@]} + ${#scr[@]} + ${#oapi[@]} ))" -gt 0 ] && add "${pre}db patches" "." "node packages/db-migrations/bin/patcher.mjs"
      [ "${#integ[@]}" -gt 0 ] && add "${pre}$p integration" "$p" "VERIFIER_VERSION=0 npx jest --selectProjects integration --forceExit --maxWorkers=2 $(rel "$p" "${integ[@]}")"
      [ "${#scr[@]}" -gt 0 ] && add "${pre}$p scripts" "$p" "VERIFIER_VERSION=0 npx jest --selectProjects scripts --forceExit --maxWorkers=2 $(rel "$p" "${scr[@]}")"
      [ "${#oapi[@]}" -gt 0 ] && add "${pre}$p oauth-api" "$p" "VERIFIER_VERSION=0 npx jest --selectProjects oauth-api --forceExit --maxWorkers=1 $(rel "$p" "${oapi[@]}")"
      true ;;
    packages/fxa-react)
      add "${pre}$p tests" "$p" "npx jest --env=jest-environment-jsdom --findRelatedTests $r" ;;
    packages/fxa-profile-server)
      add "${pre}$p tests" "$p" "NODE_ENV=test npx jest --findRelatedTests $r" ;;
    packages/fxa-admin-server)
      # Its jest maps @fxa/* to ../dist/, which exists only after fxa-start builds it,
      # and then may be stale; --modulePaths resolves the library source instead.
      add "${pre}$p tests" "$p" "npx jest --runInBand --forceExit --modulePaths=/workspace --findRelatedTests $r" ;;
    packages/fxa-admin-panel|packages/fxa-event-broker)
      add "${pre}$p tests" "$p" "npx jest --findRelatedTests $r" ;;
    packages/db-migrations)
      add "${pre}$p tests" "$p" "NODE_OPTIONS=--experimental-vm-modules npx jest --no-coverage --forceExit --findRelatedTests $r" ;;
    packages/fxa-shared)
      # Mocha under test/, mirroring the source path; nestjs/ uses jest.
      mt=(); nj=()
      for f in "${code[@]}"; do g="${f#"$p"/}"
        case "$g" in
          nestjs/*) nj+=("$g") ;;
          test/*.spec.ts) mt+=("$g") ;;
          *) [ -f "$p/test/${g%.ts}.spec.ts" ] && mt+=("test/${g%.ts}.spec.ts") ;;
        esac; done
      [ "${#mt[@]}" -gt 0 ] && add "${pre}$p tests" "$p" "TS_NODE_PROJECT=tsconfig.cjs.json npx mocha -r ts-node/register/transpile-only -r tsconfig-paths/register -r ./scripts/preload-chai.mjs -g '#integration' --invert $(printf '%q ' "${mt[@]}")"
      [ "${#nj[@]}" -gt 0 ] && add "${pre}$p nestjs tests" "$p" "npx jest --runInBand --findRelatedTests $(printf '%q ' "${nj[@]}")"
      [ "${#mt[@]}${#nj[@]}" = 00 ] && add "${pre}$p tests" "." "echo 'fxa-shared: no mirrored test/ spec for these files'" ;;
    packages/fxa-auth-client)
      # Mocha, not jest: jest finds 0 tests here and fails. Tests are test/<name>.ts.
      at=(); for f in "${code[@]}"; do g="${f#"$p"/}"; b="$(basename "${g%.ts}")"
        case "$g" in test/*) at+=("$g") ;; *) [ -f "$p/test/$b.ts" ] && at+=("test/$b.ts") ;; esac; done
      if [ "${#at[@]}" -gt 0 ]; then add "${pre}$p tests" "$p" "TS_NODE_PROJECT=tsconfig.cjs.json npx mocha -r ts-node/register/transpile-only $(printf '%q ' "${at[@]}")"
      else add "${pre}$p tests" "." "echo 'fxa-auth-client: no test/<name>.ts for these files'"; fi ;;
    packages/123done)
      add "${pre}$p tests" "." "echo '123done has no tests'" ;;
    apps/payments/next)
      # Checked 2026-09-27 on main: all 18 suites fail to transform in the VM
      # (babel-jest 30 under jest 29). CI covers them; do not blame the change.
      add "${pre}$p tests" "." "echo 'payments-next jest does not run in the VM on main (babel-jest 30 under jest 29); CI covers it'" ;;
    packages/fxa-content-server)
      add "${pre}$p tests" "." "echo 'content-server has no unit runner; covered by functional tests (/fxa-functional-local)'" ;;
    packages/functional-tests)
      for f in "${code[@]}"; do case "$f" in *.spec.ts) add "${pre}$p $(basename "$f")" "." "bash ~/.claude/skills/fxa-functional-local/run.sh ${f#packages/functional-tests/}" ;; esac; done ;;
    libs/*|apps/*)
      cfg="$(nearest_jest "$p")"
      if [ -n "$cfg" ]; then add "${pre}$p tests" "." "npx jest -c $cfg --findRelatedTests $(printf '%q ' "${code[@]}")"
      else add "${pre}$p tests" "." "echo 'no jest config for $p; check its project.json for the test target'"; fi ;;
    *)
      add "${pre}$p tests" "$p" "npx jest --findRelatedTests $r" ;;
  esac
  if [ "$LINT" = 1 ]; then
    # fxa-settings' CI build treats a lint warning as an error (CI=true), so a warning fails the row here too.
    add "${pre}$p lint" "$p" "npx eslint $([ "$p" = packages/fxa-settings ] && echo '--max-warnings 0 ')$r"
    # The App commits through the API, so no lint-staged hook formats the change: format here, as the hook would.
    add "${pre}$p format" "$p" "fmt_files $(rel "$p" "${fs[@]}")"
  fi
  if [ "$TYPES" = 1 ]; then
    case "$p" in
      packages/fxa-auth-server) add "${pre}$p types" "$p" "npx tsc --noEmit -p tsconfig.build.json" ;;
      # Both fail on main in the VM (checked 2026-09-27); CI's compile target runs tsc on them.
      packages/fxa-profile-server|packages/functional-tests) add "${pre}$p types" "$p" "tsc_files tsconfig.json $r" ;;
      libs/*) for t in tsconfig.lib.json tsconfig.app.json tsconfig.json; do [ -f "$p/$t" ] && { add "${pre}$p types" "$p" "npx tsc --noEmit -p $t"; break; }; done ;;
      *) [ -f "$p/tsconfig.json" ] && add "${pre}$p types" "$p" "npx tsc --noEmit" ;;
    esac
  fi
done
}

if [ -n "$PLAN" ]; then
  [ -f "$PLAN" ] && jq -e '.items | type == "array"' "$PLAN" >/dev/null 2>&1 \
    || { echo "ERROR: $PLAN is not a test plan; see /fxa-test-plan."; exit 2; }
  specs=() funcs=() checks=() taken=()
  while IFS=$'\x1f' read -r level spec grepf behavior crun cexpect cstack; do
    case "$level" in
      check)
        # A direct observation of the behavior, e.g. curl against the running
        # stack; PASS when the output matches the expected pattern.
        [ -n "$crun" ] && [ -n "$cexpect" ] || { add "plan missing: check '${behavior:0:30}' needs run and expect" "." "false"; continue; }
        checks+=("${behavior:0:48}"$'\x1f'"$crun"$'\x1f'"$cexpect"$'\x1f'"$cstack") ;;
      ci) add "plan CI: ${behavior:0:48}" "." "true" ;;
      storybook) add "plan storybook: ${spec:-${behavior:0:40}}" "." "true" ;;
      types) TYPES=1 ;;
      functional)
        if [ -f "$spec" ]; then funcs+=("${spec#packages/functional-tests/}"$'\t'"$grepf"); taken+=("$spec")
        else add "plan missing: $spec" "." "echo 'the plan names $spec, which does not exist'; false"; fi ;;
      *)
        if [ -f "$spec" ]; then specs+=("$spec"); taken+=("$spec")
        else add "plan missing: $spec" "." "echo 'the plan names $spec, which does not exist'; false"; fi ;;
    esac
  done < <(jq -r '.items[] | [(.level // "unit"), (.spec // ""), (.grep // ""), (.behavior // ""), (.run // ""), (.expect // ""), (if .needs_stack == false then "no" else "yes" end)] | map(gsub("[\t\n\u001f]"; " ")) | join("\u001f")' "$PLAN")
  [ "${#specs[@]}" -gt 0 ] && plan_files "plan " "${specs[@]}"
  # The safety net: the changed files' related specs, minus what the plan runs.
  net=(); for f in "${files[@]}"; do printf '%s\n' "${taken[@]}" | grep -qxF -- "$f" || net+=("$f"); done
  [ "${#net[@]}" -gt 0 ] && plan_files "net " "${net[@]}"
  # Checks and functional specs last: they start the stack, which needs the
  # memory the unit and integration runs used. One at a time.
  for ck in "${checks[@]}"; do IFS=$'\x1f' read -r cb cr ce cs <<<"$ck"
    pre=""; [ "$cs" = yes ] && pre="bash ~/.claude/skills/fxa-stack/stack.sh ensure >/dev/null || { echo 'the stack did not start; run /fxa-stack diagnose'; exit 3; }; "
    add "plan check: $cb" "." "${pre}out=\$(bash -c $(printf %q "$cr") 2>&1); printf '%s\\n' \"\$out\"; printf '%s' \"\$out\" | grep -qE $(printf %q "$ce") || { echo 'expected to match: '$(printf %q "$ce"); exit 1; }"; done
  for fu in "${funcs[@]}"; do IFS=$'\t' read -r fs fg <<<"$fu"
    add "plan functional $(basename "$fs")" "." "bash ~/.claude/skills/fxa-functional-local/run.sh $(printf %q "$fs")${fg:+ $(printf %q "$fg")}"; done
elif [ "$REVERT" = 0 ]; then
  plan_files "" "${files[@]}"
fi

# A widely imported file relates to many specs; fall back to its sibling spec.
# Sets capped (the command to run) and capnote (for the row label).
cap_related() {
  local dir="$1" cmd="$2"; capped="$2" capnote=""
  case "$cmd" in *--findRelatedTests*) ;; *) return 0 ;; esac
  local n; n="$(cd "$dir" && eval "${cmd/--findRelatedTests/--listTests --findRelatedTests}" 2>/dev/null | grep -c '\.\(spec\|test\)\.' || true)"
  [ "${n:-0}" -gt "$MAX_RELATED" ] || return 0
  local sib; sib="$(sed 's/.*--findRelatedTests //' <<<"$cmd" | tr ' ' '\n' | sed -E 's/\.(tsx?|jsx?)$//' | while read -r b; do
    for e in .test.tsx .test.ts .spec.ts .spec.tsx; do [ -f "$dir/$b$e" ] && echo "$b$e"; done; done | tr '\n' ' ')"
  # No sibling: leave the row to CI, since all n related specs come near the whole suite.
  if [ -n "$sib" ]; then capped="${cmd%%--findRelatedTests*}$sib" capnote=" (sibling only; $n related not run)"
  else capped="" capnote=" ($n related specs, no sibling)"; fi
  return 0
}

# --revert: run the tests with the non-test files of the diff at the merge-base
# (the fix removed), then with the fix, and print both verdicts. Never git stash:
# it fails on a staged file. git show writes the base version and leaves the index alone.
if [ "$REVERT" = 1 ]; then
  base="$(git merge-base HEAD origin/main 2>/dev/null || echo HEAD)"
  tests=() fix=()
  [ "$given" -gt 0 ] && tests=("${files[@]}")
  while IFS= read -r f; do
    printf '%s\n' "${tests[@]}" | grep -qxF -- "$f" && continue
    if is_test "$f"; then [ "$given" -gt 0 ] || tests+=("$f"); else fix+=("$f"); fi
  done < <({ git diff --name-only --no-renames "$base"; git ls-files -o --exclude-standard; } | grep -vE '^(\.fxa-|ai/|artifacts/)' | sort -u)
  [ "${#fix[@]}" -gt 0 ] || { echo "No non-test changes against $base to revert."; exit 2; }

  # One row per test file; with no test files, the related tests of the fix.
  # The commands are fixed now, on the fixed tree, so both runs run the same thing.
  LINT=0 TYPES=0 rows=() setup=""
  add_rows() { local p label dir cmd; for p in "${plan[@]}"; do IFS='|' read -r label dir cmd <<<"$p"
    case "$label" in *"db patches") setup="$cmd"; continue ;; esac
    cap_related "$dir" "$cmd"; cmd="$capped"; [ -n "$cmd" ] || continue; case "$cmd" in *--findRelatedTests*) cmd="$cmd --passWithNoTests" ;; esac
    rows+=("${1:-$label}$capnote|$dir|$cmd"); done; }
  if [ "${#tests[@]}" -gt 0 ]; then for t in "${tests[@]}"; do plan=(); plan_files "" "$t"; add_rows "$t"; done
  else plan=(); plan_files "" "${fix[@]}"; add_rows; fi
  [ "${#rows[@]}" -gt 0 ] || { echo "No tests to run; pass the spec paths."; exit 2; }
  echo "Fix files, restored from $base for the run without the fix:"; printf '  %s\n' "${fix[@]}"

  sums() { local f; for f in "${fix[@]}"; do
    if [ -e "$f" ]; then printf '%s %s\n' "$(git hash-object --no-filters -- "$f")" "$f"; else printf -- '- %s\n' "$f"; fi; done; }
  bak="$(mktemp -d)" before="$(sums)" swapped=0
  for f in "${fix[@]}"; do [ -e "$f" ] || continue
    mkdir -p "$bak/$(dirname "$f")" && cp -a "$f" "$bak/$f" || { echo "ERROR: could not back up $f; nothing changed."; exit 2; }; done
  put_back() { # the fixed versions back, byte for byte; a new file of the fix is part of it
    [ "$swapped" = 1 ] || return 0
    local f; for f in "${fix[@]}"; do
      if [ -e "$bak/$f" ]; then mkdir -p "$(dirname "$f")" && cp -a "$bak/$f" "$f"; else rm -f "$f"; fi; done
    if [ "$(sums)" = "$before" ]; then swapped=0; rm -rf "$bak"
    else echo "ERROR: the fix files do not match their checksums after the restore. The backup is in $bak."; return 1; fi; }
  trap put_back EXIT; trap 'exit 130' INT TERM HUP

  # pm2 restarts auth on a change in its bin/, config/ or lib/ only.
  srv=0; for f in "${fix[@]}"; do case "$f" in packages/fxa-auth-server/*|packages/fxa-shared/*|libs/*) srv=1 ;; esac; done
  [ "$srv" = 1 ] && curl -sf -m 5 localhost:9000/__heartbeat__ >/dev/null 2>&1 || srv=0
  settle() {
    [ "$srv" = 1 ] || return 0
    sleep 5 # ponytail: fixed grace for the pm2 watch restart to start; poll pm2 restart_time if it races
    printf '%s\n' "${fix[@]}" | grep -qvE '^packages/fxa-auth-server/(bin|config|lib)/' && pm2 restart auth >/dev/null 2>&1 9>&-
    for _ in $(seq 60); do curl -sf -m 5 localhost:9000/__heartbeat__ >/dev/null 2>&1 && return 0; sleep 2; done
    echo "ERROR: the auth heartbeat did not come back in 2 minutes; see: pm2 logs auth --lines 50 --nostream"; return 1; }

  # One folder per user: a fixed /tmp path that another user made first refused every write.
  logs="${TMPDIR:-/tmp}/fxa-verify-revert-$(id -u)"; rm -rf "$logs"; mkdir -p "$logs"
  declare -A res=()
  run_rows() { local i label dir cmd v; for i in "${!rows[@]}"; do IFS='|' read -r label dir cmd <<<"${rows[$i]}"
    if (cd "$dir" && eval "$cmd") > "$logs/$1-$i.log" 2>&1 9>&-; then v=PASS; else v=FAIL; fi
    case "$cmd" in *fxa-functional-local*) ;; *) [ "$v" = PASS ] && ! grep -qE 'Tests: +([0-9]+ [a-z]+, )*[0-9]+ passed|[0-9]+ passing' "$logs/$1-$i.log" && v=NONE ;; esac
    res[$1,$i]=$v; echo "  $1 the fix: $v  $label"; done; }

  [ -z "$setup" ] || eval "$setup" > "$logs/setup.log" 2>&1 9>&- || { echo "ERROR: $setup failed; see $logs/setup.log"; exit 2; }
  swapped=1
  for f in "${fix[@]}"; do
    if git cat-file -e "$base:$f" 2>/dev/null; then mkdir -p "$(dirname "$f")" && git show "$base:$f" > "$f"; else rm -f "$f"; fi; done
  settle || exit 2
  run_rows without
  put_back || exit 2
  settle || exit 2
  run_rows with

  proof=0; echo; printf '  %-60s %-17s %s\n' "test" "without the fix" "with the fix"
  for i in "${!rows[@]}"; do w="${res[without,$i]}" h="${res[with,$i]}" note=""
    [ "$h" = PASS ] || note="  does not pass with the fix"
    case "$w" in PASS) note="  passes without the fix: it does not prove the change" ;; NONE) note="  ran no tests" ;; esac
    [ "$w" = FAIL ] && [ "$h" = PASS ] || proof=1
    printf '  %-60s %-17s %s%s\n' "${rows[$i]%%|*}" "$w" "$h" "$note"; done
  echo "Logs: $logs"
  # The record the PR's Risk section reads: whether the tests prove the change, then each row.
  { echo "fxa-verify-revert $(date -u +%FT%TZ) proof=$([ "$proof" = 0 ] && echo yes || echo no)"
    for i in "${!rows[@]}"; do printf '%s %s %s\n' "${res[without,$i]}" "${res[with,$i]}" "${rows[$i]%%|*}"; done; } > .fxa-verify-revert.txt 2>/dev/null || true
  exit "$proof"
fi

# --failed: rerun only last time's FAIL and NONE rows; the other rows keep last
# time's verdict. A row file beside the verdict holds each row's command.
# --stale also reruns every row of the package of a file changed after the last run started,
# a functional or check row when a source file changed, and plans net rows for a package with no row.
ROWS=/workspace/.fxa-verify-rows.tsv kept_rows=()
if [ "$FAILED$STALE" != 00 ]; then
  [ -s "$ROWS" ] || { echo "No earlier run to rerun. Run: bash $0 --run"; exit 2; }
  stale=() own=() named=() src=0 ref="$START"; [ -f "$ref" ] || ref=/workspace/.fxa-verify-verdict.txt
  if [ "$STALE" = 1 ]; then for f in "${files[@]}"; do [ "$f" -nt "$ref" ] || continue
    stale+=("$f"); own+=("$(owner "$f")"); is_test "$f" || src=1; done; fi
  plan=()
  while IFS=$'\t' read -r v entry line; do
    re=0; case "$v" in FAIL|NONE) re=1 ;; esac
    IFS='|' read -r l d c <<<"$entry"
    [ "$src" = 1 ] && case "$l|$c" in "plan check: "*|*fxa-functional-local*) re=1 ;; esac
    for i in ${stale[@]+"${!stale[@]}"}; do f="${stale[$i]}"
      # A functional row reruns only for its own spec; any other row for any file of its package.
      case "$c" in *fxa-functional-local*) ;; *) case " $l " in *" ${own[$i]} "*) re=1; named+=("$f"); continue ;; esac ;; esac
      q="$(printf %q "${f#"$d"/}")" fq="$(printf %q "${f#packages/functional-tests/}")"
      case " $c " in *" $q "*|*" $fq "*) re=1; named+=("$f") ;; esac; done
    if [ "$re" = 1 ]; then plan+=("$entry")
    else case "$line" in *.log) line="${line% *} (kept; its log is gone)" ;; esac; kept_rows+=("$v"$'\t'"$entry"$'\t'"$line"); fi
  done < "$ROWS"
  new=(); for f in ${stale[@]+"${stale[@]}"}; do printf '%s\n' ${named[@]+"${named[@]}"} | grep -qxF -- "$f" || new+=("$f"); done
  [ "${#new[@]}" -gt 0 ] && plan_files "net " "${new[@]}"
  [ "${#plan[@]}" -gt 0 ] || { echo "Nothing failed in the last run$([ "$STALE" = 1 ] && echo ', and no file changed after it')."; exit 0; }
  RUN=1
fi

# The same command twice (a type-check the plan and the net both ask for, or a kept row) runs once.
declare -A seen_cmd=(); kept=()
for r in ${kept_rows[@]+"${kept_rows[@]}"}; do IFS=$'\t' read -r _ e _ <<<"$r"; IFS='|' read -r _ dir cmd <<<"$e"; seen_cmd["$dir|$cmd"]=1; done
for i in "${!plan[@]}"; do IFS='|' read -r label dir cmd <<<"${plan[$i]}"
  case "$label" in "plan CI: "*|"plan storybook: "*|"plan missing: "*) kept+=("${plan[$i]}"); continue ;; esac
  [ -n "${seen_cmd["$dir|$cmd"]:-}" ] && continue; seen_cmd["$dir|$cmd"]=1; kept+=("${plan[$i]}"); done
plan=("${kept[@]}")

echo "Plan (${#files[@]} changed file(s)):"
# A run names the rows only; each row's log starts with the command it ran.
for i in "${!plan[@]}"; do IFS='|' read -r label dir cmd <<<"${plan[$i]}"
  if [ "$RUN" = 1 ]; then printf '  %s\n' "$label"; else printf '  %-40s %s\n' "$label" "(cd $dir && $cmd)"; fi; done
[ "$RUN" = 1 ] || { echo; echo "Run it with: bash $0 --run${PLAN:+ --plan $PLAN}"; exit 0; }

logs="${TMPDIR:-/tmp}/fxa-verify-$(id -u)"; rm -rf "$logs"; mkdir -p "$logs"
fail=0; results=() failed_logs=()
for i in "${!plan[@]}"; do
  IFS='|' read -r label dir cmd <<<"${plan[$i]}"
  case "$label" in
    "plan CI: "*) results+=("$(printf '%-4s %-40s' CI "$label")  left to CI"); continue ;;
    "plan storybook: "*) results+=("$(printf '%-4s %-40s' TODO "$label")  run /fxa-storybook-capture"); continue ;;
  esac
  cap_related "$dir" "$cmd"; cmd="$capped"
  [ -n "$cmd" ] || { results+=("$(printf '%-4s %-40s' CI "$label$capnote")  left to CI"); continue; }
  # No spec imports the file (a route that only integration specs cover): Jest
  # would exit 1 on "No tests found". Say so as NOREL, not as a failure.
  case "$cmd" in *--findRelatedTests*) cmd="$cmd --passWithNoTests" ;; esac
  start=$(date +%s)
  if (cd "$dir" && printf '$ %s\n' "$cmd" && eval "$cmd") > "$logs/$i.log" 2>&1 9>&-; then v=PASS; else v=FAIL; fail=1; fi
  # Jest can exit 0 having run nothing; that proves nothing, so say so.
  case "$label" in *tests|*unit|*integration|*scripts|*oauth-api)
    [ "$v" = PASS ] && ! grep -qE 'Tests: +([0-9]+ [a-z]+, )*[0-9]+ passed|[0-9]+ passing' "$logs/$i.log" && v=NONE
    [ "$v" = NONE ] && grep -q 'No tests found' "$logs/$i.log" && v=NOREL ;;
  esac
  results+=("$(printf '%-4s %-40s %4ss  %s' "$v" "$label$capnote" "$(( $(date +%s) - start ))" "$logs/$i.log")")
  [ "$v" = FAIL ] && failed_logs+=("$label|$logs/$i.log")
done
for r in ${kept_rows[@]+"${kept_rows[@]}"}; do results+=("${r##*$'\t'}"); done
echo; echo "Verdict:"; printf '  %s\n' "${results[@]}"
# After the table, so a run piped to tail still shows why each row failed.
for fl in ${failed_logs[@]+"${failed_logs[@]}"}; do echo; echo "---- ${fl%%|*} failed; last lines:"; tail -15 "${fl#*|}"; done
[ "$fail" = 0 ] || { echo; echo "Next: fix the failure, then rerun the failed and changed rows: bash $0 --stale"; }
# The record the self-check and the PR body read. .fxa- keeps it out of the commit.
note=""; [ "$FAILED" = 1 ] && note=" (reran ${#plan[@]} failed row(s); ${#kept_rows[@]} kept from the last run)"
[ "$STALE" = 1 ] && note=" (reran ${#plan[@]} failed or changed row(s); ${#kept_rows[@]} kept from the last run)"
{ echo "fxa-verify $(date -u +%FT%TZ)${PLAN:+ plan=$PLAN}${note}"; printf '%s\n' "${results[@]}"; } > /workspace/.fxa-verify-verdict.txt
# --failed skips the changed files, so it keeps the old start time for the next --stale.
[ "$FAILED$STALE" = 10 ] || mv -f "$START.tmp" "$START" 2>/dev/null || true
{ for i in "${!plan[@]}"; do printf '%s\t%s\t%s\n' "${results[$i]%% *}" "${plan[$i]}" "${results[$i]}"; done
  for r in ${kept_rows[@]+"${kept_rows[@]}"}; do printf '%s\n' "$r"; done; } > "$ROWS"
# One line per run, for the host's metrics: what ran, what failed, how long.
printf '{"at":%s,"mode":"%s","rows":%s,"fail":%s,"secs":%s}\n' "$(date +%s)" "$([ "$STALE" = 1 ] && echo stale || { [ "$FAILED" = 1 ] && echo failed; } || echo full)" \
  "${#plan[@]}" "$(printf '%s\n' "${results[@]}" | grep -c '^FAIL')" "$(( $(date +%s) - VSTART ))" >> /workspace/.fxa-verify-runs.jsonl 2>/dev/null || true
exit "$fail"
