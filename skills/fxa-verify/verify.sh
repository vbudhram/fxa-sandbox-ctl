#!/usr/bin/env bash
# Plan, then run, the fastest correct checks for the changed files. See SKILL.md.
#   verify.sh [--run] [--types] [--no-lint] [file...]
# With no files: the working diff against origin/main, untracked files included.
set -u
cd /workspace || exit 2
RUN=0 TYPES=0 LINT=1 MAX_RELATED=15
files=()
for a in "$@"; do
  case "$a" in --run) RUN=1 ;; --types) TYPES=1 ;; --no-lint) LINT=0 ;; *) files+=("$a") ;; esac
done
if [ "${#files[@]}" -eq 0 ]; then
  base="$(git merge-base HEAD origin/main 2>/dev/null || echo HEAD)"
  mapfile -t files < <({ git diff --name-only --diff-filter=d "$base"; git ls-files -o --exclude-standard; } \
    | grep -vE '^(\.fxa-|ai/|artifacts/)' | sort -u)
fi
[ "${#files[@]}" -gt 0 ] || { echo "No changed files."; exit 0; }
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

declare -A byproj
for f in "${files[@]}"; do [ -e "$f" ] || continue; p="$(owner "$f")"; byproj[$p]+="$f "; done

plan=() # "label|dir|command"
add() { plan+=("$1|$2|$3"); }
rel() { local p="$1"; shift; local out=(); for f in "$@"; do out+=("${f#"$p"/}"); done; printf '%q ' "${out[@]}"; }

for p in $(printf '%s\n' "${!byproj[@]}" | sort); do
  read -r -a fs <<<"${byproj[$p]}"
  code=(); for f in "${fs[@]}"; do case "$f" in *.ts|*.tsx|*.js|*.jsx|*.mjs) code+=("$f") ;; esac; done
  [ "${#code[@]}" -gt 0 ] || { add "$p" "." "echo 'no code changed (docs, config, or l10n only)'"; continue; }
  r="$(rel "$p" "${code[@]}")"
  case "$p" in
    packages/fxa-settings)
      add "$p tests" "$p" "CI=true SKIP_PREFLIGHT_CHECK=true node scripts/test.js --watchAll=false --findRelatedTests $r" ;;
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
      [ "${#unit[@]}" -gt 0 ] && add "$p unit" "$p" "env -u SNS_TOPIC_ENDPOINT yarn test --maxWorkers=2 --findRelatedTests $(rel "$p" "${unit[@]}")"
      # The fxa DB has no tables until the patcher runs (fxa-start runs it); without
      # it the suite waits 63 s and fails on ER_NO_SUCH_TABLE. It is fast and idempotent.
      [ "$(( ${#integ[@]} + ${#scr[@]} + ${#oapi[@]} ))" -gt 0 ] && add "db patches" "." "node packages/db-migrations/bin/patcher.mjs"
      [ "${#integ[@]}" -gt 0 ] && add "$p integration" "$p" "VERIFIER_VERSION=0 npx jest --selectProjects integration --forceExit --maxWorkers=2 $(rel "$p" "${integ[@]}")"
      [ "${#scr[@]}" -gt 0 ] && add "$p scripts" "$p" "VERIFIER_VERSION=0 npx jest --selectProjects scripts --forceExit --maxWorkers=2 $(rel "$p" "${scr[@]}")"
      [ "${#oapi[@]}" -gt 0 ] && add "$p oauth-api" "$p" "VERIFIER_VERSION=0 npx jest --selectProjects oauth-api --forceExit --maxWorkers=1 $(rel "$p" "${oapi[@]}")"
      true ;;
    packages/fxa-react)
      add "$p tests" "$p" "npx jest --env=jest-environment-jsdom --findRelatedTests $r" ;;
    packages/fxa-profile-server)
      add "$p tests" "$p" "NODE_ENV=test npx jest --findRelatedTests $r" ;;
    packages/fxa-admin-server)
      # Its jest maps @fxa/* to ../dist/, which exists only after fxa-start builds it,
      # and then may be stale; --modulePaths resolves the library source instead.
      add "$p tests" "$p" "npx jest --runInBand --forceExit --modulePaths=/workspace --findRelatedTests $r" ;;
    packages/fxa-admin-panel|packages/fxa-event-broker)
      add "$p tests" "$p" "npx jest --findRelatedTests $r" ;;
    packages/db-migrations)
      add "$p tests" "$p" "NODE_OPTIONS=--experimental-vm-modules npx jest --no-coverage --forceExit --findRelatedTests $r" ;;
    packages/fxa-shared)
      # Mocha under test/, mirroring the source path; nestjs/ uses jest.
      mt=(); nj=()
      for f in "${code[@]}"; do g="${f#"$p"/}"
        case "$g" in
          nestjs/*) nj+=("$g") ;;
          test/*.spec.ts) mt+=("$g") ;;
          *) [ -f "$p/test/${g%.ts}.spec.ts" ] && mt+=("test/${g%.ts}.spec.ts") ;;
        esac; done
      [ "${#mt[@]}" -gt 0 ] && add "$p tests" "$p" "TS_NODE_PROJECT=tsconfig.cjs.json npx mocha -r ts-node/register/transpile-only -r tsconfig-paths/register -r ./scripts/preload-chai.mjs -g '#integration' --invert $(printf '%q ' "${mt[@]}")"
      [ "${#nj[@]}" -gt 0 ] && add "$p nestjs tests" "$p" "npx jest --runInBand --findRelatedTests $(printf '%q ' "${nj[@]}")"
      [ "${#mt[@]}${#nj[@]}" = 00 ] && add "$p tests" "." "echo 'fxa-shared: no mirrored test/ spec for these files'" ;;
    packages/fxa-auth-client)
      # Mocha, not jest: jest finds 0 tests here and fails. Tests are test/<name>.ts.
      at=(); for f in "${code[@]}"; do g="${f#"$p"/}"; b="$(basename "${g%.ts}")"
        case "$g" in test/*) at+=("$g") ;; *) [ -f "$p/test/$b.ts" ] && at+=("test/$b.ts") ;; esac; done
      if [ "${#at[@]}" -gt 0 ]; then add "$p tests" "$p" "TS_NODE_PROJECT=tsconfig.cjs.json npx mocha -r ts-node/register/transpile-only $(printf '%q ' "${at[@]}")"
      else add "$p tests" "." "echo 'fxa-auth-client: no test/<name>.ts for these files'"; fi ;;
    packages/123done)
      add "$p tests" "." "echo '123done has no tests'" ;;
    apps/payments/next)
      # Checked 2026-09-27 on main: all 18 suites fail to transform in the VM
      # (babel-jest 30 under jest 29). CI covers them; do not blame the change.
      add "$p tests" "." "echo 'payments-next jest does not run in the VM on main (babel-jest 30 under jest 29); CI covers it'" ;;
    packages/fxa-content-server)
      add "$p tests" "." "echo 'content-server has no unit runner; covered by functional tests (/fxa-functional-local)'" ;;
    packages/functional-tests)
      for f in "${code[@]}"; do case "$f" in *.spec.ts) add "$p $(basename "$f")" "." "bash ~/.claude/skills/fxa-functional-local/run.sh ${f#packages/functional-tests/}" ;; esac; done ;;
    libs/*|apps/*)
      cfg="$(nearest_jest "$p")"
      if [ -n "$cfg" ]; then add "$p tests" "." "npx jest -c $cfg --findRelatedTests $(printf '%q ' "${code[@]}")"
      else add "$p tests" "." "echo 'no jest config for $p; check its project.json for the test target'"; fi ;;
    *)
      add "$p tests" "$p" "npx jest --findRelatedTests $r" ;;
  esac
  if [ "$LINT" = 1 ]; then add "$p lint" "$p" "npx eslint $r"; fi
  if [ "$TYPES" = 1 ]; then
    case "$p" in
      packages/fxa-auth-server) add "$p types" "$p" "npx tsc --noEmit -p tsconfig.build.json" ;;
      # Both fail on main (checked 2026-09-27) and CI does not type-check them.
      packages/fxa-profile-server|packages/functional-tests) add "$p types" "." "echo 'tsc fails on main here already; not a CI target, skipped'" ;;
      libs/*) for t in tsconfig.lib.json tsconfig.app.json tsconfig.json; do [ -f "$p/$t" ] && { add "$p types" "$p" "npx tsc --noEmit -p $t"; break; }; done ;;
      *) [ -f "$p/tsconfig.json" ] && add "$p types" "$p" "npx tsc --noEmit" ;;
    esac
  fi
done

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

echo "Plan (${#files[@]} changed file(s)):"
for i in "${!plan[@]}"; do IFS='|' read -r label dir cmd <<<"${plan[$i]}"; printf '  %-40s %s\n' "$label" "(cd $dir && $cmd)"; done
[ "$RUN" = 1 ] || { echo; echo "Run it with: bash $0 --run"; exit 0; }

logs=/tmp/fxa-verify; rm -rf "$logs"; mkdir -p "$logs"
fail=0; results=()
for i in "${!plan[@]}"; do
  IFS='|' read -r label dir cmd <<<"${plan[$i]}"
  cmd="$(cap_related "$dir" "$cmd")"
  start=$(date +%s)
  if (cd "$dir" && eval "$cmd") > "$logs/$i.log" 2>&1; then v=PASS; else v=FAIL; fail=1; fi
  # Jest can exit 0 having run nothing; that proves nothing, so say so.
  case "$label" in *tests|*unit|*integration|*scripts|*oauth-api)
    [ "$v" = PASS ] && ! grep -qE 'Tests: +([0-9]+ [a-z]+, )*[0-9]+ passed|[0-9]+ passing' "$logs/$i.log" && v=NONE ;;
  esac
  results+=("$(printf '%-4s %-40s %4ss  %s' "$v" "$label" "$(( $(date +%s) - start ))" "$logs/$i.log")")
  [ "$v" = FAIL ] && { echo "---- $label failed; last lines:"; tail -25 "$logs/$i.log"; }
done
echo; echo "Verdict:"; printf '  %s\n' "${results[@]}"
exit "$fail"
