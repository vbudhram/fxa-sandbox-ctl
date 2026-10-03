#!/usr/bin/env bash
# check.sh: the mechanical half of /fxa-vm-selfcheck, in one call. It prints the
# diff, the test lines to fix, what to compile, frozen paths, the verify verdict and
# the functional spec tags. Lines that need attention start with "! ". The judgment
# checks stay in SKILL.md: 1 (which assertion fails on a revert), 2 (sibling call
# sites) and 5 (the PR body's claims).
#   bash ~/.claude/skills/fxa-vm-selfcheck/check.sh [repo]   (default /workspace)
set -uo pipefail
cd "${1:-/workspace}" || exit 2
ref="origin/${FXA_WORKTREE_BASE:-main}"
BASE="$(git merge-base HEAD "$ref" 2>/dev/null)" || { echo "! no merge base with $ref"; exit 2; }
n=0; flag() { echo "! $*"; n=$((n + 1)); }
changed="$( { git diff --name-only "$BASE"; git ls-files --others --exclude-standard; } | grep -v '^\.fxa-' | sort -u)"
untracked="$(git ls-files --others --exclude-standard | grep -v '^\.fxa-' || true)"

echo "== Step 0: the diff from ${BASE:0:10}"
git --no-pager diff --stat=100 "$BASE" -- . ':(exclude).fxa-*' | tail -n 20
[ -n "$untracked" ] && { echo "Untracked (read each one; a diff hides them):"; sed 's/^/  /' <<< "$untracked"; }

echo "== Check 1: test lines"
tests="$(grep -E '\.(test|spec)\.(t|j)sx?$' <<< "$changed" || true)"
if [ -n "$tests" ]; then
  echo "Tests added or changed (name the assertion that fails on a revert, then /fxa-verify --revert):"; sed 's/^/  /' <<< "$tests"
fi
hits="$( { git --no-pager diff -U0 "$BASE" -- '*.test.tsx' | grep -E '^\+.*(fireEvent|querySelector|ByTestId)'
           for f in $(grep -E '\.test\.tsx$' <<< "$untracked" || true); do grep -nE 'fireEvent|querySelector|ByTestId' "$f" | sed "s#^#$f:#"; done; } 2>/dev/null | head -10)"
[ -n "$hits" ] && while IFS= read -r h; do flag "react test uses fireEvent, querySelector or ByTestId (see .claude/rules/testing/react.md): ${h:0:160}"; done <<< "$hits"

echo "== Check 3: compile"
pkgs=""
for p in $(sed -nE 's#^((packages|libs)/[^/]+)/.*\.tsx?$#\1#p' <<< "$changed" | sort -u); do
  # A removed export, or a removed line that declares a function: a type error can follow in other files.
  git --no-pager diff -U0 "$BASE" -- "$p" | grep -qE '^-[^-]*\bexport\b|^-\s*(export\s+)?(default\s+)?(async\s+)?function\s+[A-Za-z_$]|^-\s*(public |private |protected |static |async )*[A-Za-z_$][A-Za-z0-9_$]*\s*\([^)]*\)\s*(:[^{=]*)?\{' && pkgs="$pkgs $p"
done
if [ -n "$pkgs" ]; then
  for p in $pkgs; do c="$p/tsconfig.build.json"; [ -f "$c" ] || c="$p/tsconfig.json"; flag "a removed export or changed signature in $p: run npx tsc --noEmit -p $c"; done
else echo "No removed export or changed signature."; fi

echo "== Check 4: scope"
frozen="$(git show "$ref:_scripts/check-frozen.ts" 2>/dev/null | sed -n '/^const frozen/,/^\];/p' | grep -oE "['\"][^'\"]+['\"]" | tr -d "'\"")"
hit=0
for f in $changed; do for z in $frozen; do case "$f" in "$z"*) flag "frozen path (yarn check:frozen refuses the commit): $f"; hit=1 ;; esac; done; done
[ "$hit" = 0 ] && echo "No frozen path. Read the file list above against the request; revert what it does not need."

echo "== Check 6: the test plan ran"
if [ -f .fxa-test-plan.json ]; then
  if [ ! -f .fxa-verify-verdict.txt ]; then flag "no verdict: run /fxa-verify --run --plan /workspace/.fxa-test-plan.json"
  else
    grep -E '\b(FAIL|NONE|TODO)\b' .fxa-verify-verdict.txt | head -10 | while IFS= read -r l; do echo "! verdict: ${l:0:160}"; done
    n=$((n + $(grep -cE '\b(FAIL|NONE|TODO)\b' .fxa-verify-verdict.txt)))
    newer="$(find . \( -path ./node_modules -o -path ./.git -o -name node_modules \) -prune -o -newer .fxa-verify-verdict.txt -type f \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' \) -print 2>/dev/null | head -5)"
    [ -n "$newer" ] && flag "code changed after the verdict, so run the plan again: $(tr '\n' ' ' <<< "$newer")"
  fi
else echo "No test plan."; fi

echo "== Check 7: functional specs"
specs="$(grep -E '^packages/functional-tests/tests/.*\.spec\.ts$' <<< "$changed" || true)"
if [ -z "$specs" ]; then echo "No new or changed spec."; fi
for s in $specs; do
  [ -f "$s" ] || continue
  grep -qE "describe\((['\"\`])(severity-|.*#smoke)" "$s" && continue
  for nb in $(ls "$(dirname "$s")"/*.spec.ts 2>/dev/null | grep -vx "$s" | head -3); do
    grep -qE "describe\((['\"\`])(severity-|.*#smoke)" "$nb" && { flag "$s has no severity-N or #smoke tag in its describe title; $(basename "$nb") has one"; break; }
  done
done
[ -n "$specs" ] && echo "For each spec: a skip for what stage or production lacks, #phone if it sends SMS, and no assertion on a value CI does not set."

echo "== $n item(s) need attention. Now do checks 1, 2 and 5 in SKILL.md."
