#!/usr/bin/env bash
# Plan, then run, the fastest correct checks for the changed files. See SKILL.md.
#   verify.sh [--run] [--no-types] [--no-lint] [--plan <test-plan.json>] [file...]
#   verify.sh --revert [test file...]   the tests fail without the fix, pass with it
#   verify.sh --failed   rerun only the rows that failed or ran nothing last time
# With no files: the working diff against origin/main, untracked files included.
# With --plan: the specs the test plan names (see /fxa-test-plan) first, then the
# related specs of the changed files as a safety net, then any functional spec.
set -u
cd "${FXA_WORKSPACE:-/workspace}" || exit 2
RUN=0 TYPES=1 LINT=1 MAX_RELATED=15 REVERT=0 FAILED=0
files=() PLAN=""
while [ $# -gt 0 ]; do
  case "$1" in --run) RUN=1 ;; --types) TYPES=1 ;; --no-types) TYPES=0 ;; --no-lint) LINT=0 ;; --plan) PLAN="${2:?--plan needs a file}"; shift ;; --revert) REVERT=1 ;; --failed) FAILED=1 ;; *) files+=("$1") ;; esac
  shift
done
given=${#files[@]}
if [ "${#files[@]}" -eq 0 ]; then
  base="$(git merge-base HEAD origin/main 2>/dev/null || echo HEAD)"
  mapfile -t files < <({ git diff --name-only --diff-filter=d "$base"; git ls-files -o --exclude-standard; } \
    | grep -vE '^(\.fxa-|ai/|artifacts/)' | sort -u)
fi
[ "${#files[@]}" -gt 0 ] || [ -n "$PLAN" ] || { echo "No changed files."; exit 0; }
export NODE_OPTIONS="--max-old-space-size=4096 ${NODE_OPTIONS:-}"

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
    add "${pre}$p lint" "$p" "npx eslint $r"
    # The App commits through the API, so no lint-staged hook formats the change.
    add "${pre}$p format" "$p" "npx prettier --check --ignore-unknown $(rel "$p" "${fs[@]}") || { echo 'fix with: npx prettier --write <files>'; false; }"
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
cap_related() {
  local dir="$1" cmd="$2"
  case "$cmd" in *--findRelatedTests*) ;; *) echo "$cmd"; return ;; esac
  local n; n="$(cd "$dir" && eval "${cmd/--findRelatedTests/--listTests --findRelatedTests}" 2>/dev/null | grep -c '\.\(spec\|test\)\.' || true)"
  if [ "${n:-0}" -le "$MAX_RELATED" ]; then echo "$cmd"; return; fi
  local sib; sib="$(sed 's/.*--findRelatedTests //' <<<"$cmd" | tr ' ' '\n' | sed -E 's/\.(tsx?|jsx?)$//' | while read -r b; do
    for e in .test.tsx .test.ts .spec.ts .spec.tsx; do [ -f "$dir/$b$e" ] && echo "$b$e"; done; done | tr '\n' ' ')"
  echo "# ${n} related specs; running the sibling specs only" >&2
  if [ -n "$sib" ]; then echo "${cmd%%--findRelatedTests*}$sib"; else echo "$cmd"; fi
}

# --revert: run the tests with the non-test files of the diff at the merge-base
# (the fix removed), then with the fix, and print both verdicts. Never git stash:
# it fails on a staged file. git show writes the base version and leaves the index alone.
if [ "$REVERT" = 1 ]; then
  base="$(git merge-base HEAD origin/main 2>/dev/null || echo HEAD)"
  is_test() { case "$1" in *.spec.*|*.test.*|*/test/*|*/tests/*|*/__tests__/*|*/__mocks__/*|*/__snapshots__/*|packages/functional-tests/*) return 0 ;; esac; return 1; }
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
    cmd="$(cap_related "$dir" "$cmd")"; case "$cmd" in *--findRelatedTests*) cmd="$cmd --passWithNoTests" ;; esac
    rows+=("${1:-$label}|$dir|$cmd"); done; }
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
    printf '%s\n' "${fix[@]}" | grep -qvE '^packages/fxa-auth-server/(bin|config|lib)/' && pm2 restart auth >/dev/null 2>&1
    for _ in $(seq 60); do curl -sf -m 5 localhost:9000/__heartbeat__ >/dev/null 2>&1 && return 0; sleep 2; done
    echo "ERROR: the auth heartbeat did not come back in 2 minutes; see: pm2 logs auth --lines 50 --nostream"; return 1; }

  logs=/tmp/fxa-verify-revert; rm -rf "$logs"; mkdir -p "$logs"
  declare -A res=()
  run_rows() { local i label dir cmd v; for i in "${!rows[@]}"; do IFS='|' read -r label dir cmd <<<"${rows[$i]}"
    if (cd "$dir" && eval "$cmd") > "$logs/$1-$i.log" 2>&1; then v=PASS; else v=FAIL; fi
    case "$cmd" in *fxa-functional-local*) ;; *) [ "$v" = PASS ] && ! grep -qE 'Tests: +([0-9]+ [a-z]+, )*[0-9]+ passed|[0-9]+ passing' "$logs/$1-$i.log" && v=NONE ;; esac
    res[$1,$i]=$v; echo "  $1 the fix: $v  $label"; done; }

  [ -z "$setup" ] || eval "$setup" > "$logs/setup.log" 2>&1 || { echo "ERROR: $setup failed; see $logs/setup.log"; exit 2; }
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
  exit "$proof"
fi

# The same command twice (a type-check the plan and the net both ask for) runs once.
declare -A seen_cmd=(); kept=()
for i in "${!plan[@]}"; do IFS='|' read -r label dir cmd <<<"${plan[$i]}"
  case "$label" in "plan CI: "*|"plan storybook: "*|"plan missing: "*) kept+=("${plan[$i]}"); continue ;; esac
  [ -n "${seen_cmd["$dir|$cmd"]:-}" ] && continue; seen_cmd["$dir|$cmd"]=1; kept+=("${plan[$i]}"); done
plan=("${kept[@]}")

# --failed: rerun only last time's FAIL and NONE rows; the other rows keep last
# time's verdict. A row file beside the verdict holds each row's command.
ROWS=/workspace/.fxa-verify-rows.tsv kept_rows=()
if [ "$FAILED" = 1 ]; then
  [ -s "$ROWS" ] || { echo "No earlier run to rerun. Run: bash $0 --run"; exit 2; }
  plan=()
  while IFS=$'\t' read -r v entry line; do
    case "$v" in FAIL|NONE) plan+=("$entry") ;; *) kept_rows+=("$v"$'\t'"$entry"$'\t'"$line") ;; esac
  done < "$ROWS"
  [ "${#plan[@]}" -gt 0 ] || { echo "Nothing failed in the last run."; exit 0; }
  RUN=1
fi

echo "Plan (${#files[@]} changed file(s)):"
for i in "${!plan[@]}"; do IFS='|' read -r label dir cmd <<<"${plan[$i]}"; printf '  %-40s %s\n' "$label" "(cd $dir && $cmd)"; done
[ "$RUN" = 1 ] || { echo; echo "Run it with: bash $0 --run${PLAN:+ --plan $PLAN}"; exit 0; }

logs=/tmp/fxa-verify; rm -rf "$logs"; mkdir -p "$logs"
fail=0; results=()
for i in "${!plan[@]}"; do
  IFS='|' read -r label dir cmd <<<"${plan[$i]}"
  case "$label" in
    "plan CI: "*) results+=("$(printf '%-4s %-40s' CI "$label")  left to CI"); continue ;;
    "plan storybook: "*) results+=("$(printf '%-4s %-40s' TODO "$label")  run /fxa-storybook-capture"); continue ;;
  esac
  cmd="$(cap_related "$dir" "$cmd")"
  # No spec imports the file (a route that only integration specs cover): Jest
  # would exit 1 on "No tests found". Say so as NOREL, not as a failure.
  case "$cmd" in *--findRelatedTests*) cmd="$cmd --passWithNoTests" ;; esac
  start=$(date +%s)
  if (cd "$dir" && eval "$cmd") > "$logs/$i.log" 2>&1; then v=PASS; else v=FAIL; fail=1; fi
  # Jest can exit 0 having run nothing; that proves nothing, so say so.
  case "$label" in *tests|*unit|*integration|*scripts|*oauth-api)
    [ "$v" = PASS ] && ! grep -qE 'Tests: +([0-9]+ [a-z]+, )*[0-9]+ passed|[0-9]+ passing' "$logs/$i.log" && v=NONE
    [ "$v" = NONE ] && grep -q 'No tests found' "$logs/$i.log" && v=NOREL ;;
  esac
  results+=("$(printf '%-4s %-40s %4ss  %s' "$v" "$label" "$(( $(date +%s) - start ))" "$logs/$i.log")")
  [ "$v" = FAIL ] && { echo "---- $label failed; last lines:"; tail -25 "$logs/$i.log"; }
done
for r in ${kept_rows[@]+"${kept_rows[@]}"}; do results+=("${r##*$'\t'}"); done
echo; echo "Verdict:"; printf '  %s\n' "${results[@]}"
# The record the self-check and the PR body read. .fxa- keeps it out of the commit.
note=""; [ "$FAILED" = 1 ] && note=" (reran ${#plan[@]} failed row(s); ${#kept_rows[@]} kept from the last run)"
{ echo "fxa-verify $(date -u +%FT%TZ)${PLAN:+ plan=$PLAN}${note}"; printf '%s\n' "${results[@]}"; } > /workspace/.fxa-verify-verdict.txt
{ for i in "${!plan[@]}"; do printf '%s\t%s\t%s\n' "${results[$i]%% *}" "${plan[$i]}" "${results[$i]}"; done
  for r in ${kept_rows[@]+"${kept_rows[@]}"}; do printf '%s\n' "$r"; done; } > "$ROWS"
exit "$fail"
