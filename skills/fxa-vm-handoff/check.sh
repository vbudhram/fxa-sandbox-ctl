#!/usr/bin/env bash
# Check the change and the handoff file before the host ships them. See SKILL.md.
#   check.sh [--fix]   --fix formats the changed files and deletes untracked scratch files first
# Prints one line per problem. Exits 1 on a problem, 3 when only the PR text's STE style needs work.
set -u
cd "${FXA_WORKSPACE:-/workspace}" || exit 2
fix=0; [ "${1:-}" = --fix ] && fix=1
problems=() style=()

base="$(git merge-base HEAD "origin/${FXA_WORKTREE_BASE:-main}" 2>/dev/null || echo HEAD)"
files=()
while IFS= read -r f; do files+=("$f"); done < <({ git diff --name-only --diff-filter=d "$base"; git ls-files -o --exclude-standard; } \
  | grep -vE '^(\.fxa-|ai/|artifacts/)' | sort -u)

# Throwaway screenshot and debug files. /fxa-page-shot does screenshots without them.
kept=()
for f in ${files[@]+"${files[@]}"}; do
  case "$(basename "$f")" in
    zz*.spec.ts|zz*.spec.js|*.tmp.mjs|*.tmp.js|*.tmp.ts|*.tmp.cjs)
      if [ "$fix" = 1 ] && [ -n "$(git ls-files -o --exclude-standard -- "$f")" ]; then rm -f -- "$f"; echo "deleted scratch file: $f"; continue; fi
      problems+=("scratch file in the change: $f (delete it)") ;;
  esac
  kept+=("$f")
done

# A rebase can leave conflict markers; they must never reach the PR.
for f in ${kept[@]+"${kept[@]}"}; do
  [ -f "$f" ] && grep -qE '^(<{7}|>{7})( |$)' "$f" 2>/dev/null && problems+=("conflict markers remain in $f (resolve them)")
done

# The App commits through the API, so no lint-staged hook formats the change.
if [ "${#kept[@]}" -gt 0 ]; then
  if [ "$fix" = 1 ]; then
    out="$(npx prettier --list-different --ignore-unknown -- "${kept[@]}" 2>/dev/null || true)"
    [ -n "$out" ] && npx prettier --write --ignore-unknown -- $out >/dev/null 2>&1 && printf 'formatted: %s\n' $out
  fi
  out="$(npx prettier --list-different --ignore-unknown -- "${kept[@]}" 2>&1)" || {
    [ -n "$out" ] && problems+=("not formatted (run npx prettier --write on them): $(echo $out)"); }
fi

done_file=.fxa-auto-done.json; [ -s "$done_file" ] || done_file=.fxa-auto-done.json.tmp
if [ -s "$done_file" ]; then
  if ! jq -e 'type == "object" and (.issue|type) == "string" and (.branch|type) == "string"
      and (.pr_title|type) == "string" and (.pr_body|type) == "string" and (.pr_body|length) > 0
      and (.media_paths|type) == "array" and all(.media_paths[]; type == "string")' "$done_file" >/dev/null 2>&1; then
    problems+=("$done_file needs string keys issue, branch, pr_title, pr_body (not empty) and an array media_paths")
  else
    title="$(jq -r .pr_title "$done_file")"
    [[ "$title" =~ ^(feat|fix|chore|refactor|test|docs|perf|ci|build|style|revert|task|bug)\([^()]+\)!?:\ [^[:space:]] ]] \
      || problems+=("pr_title is not a scoped conventional subject like 'fix(auth): reject an expired token': $title")
    [ "${#title}" -le 100 ] || problems+=("pr_title is ${#title} characters; keep it to 100")
    [ "$(jq -r .branch "$done_file")" = "$(git branch --show-current)" ] \
      || problems+=("branch is '$(jq -r .branch "$done_file")' but the checkout is on '$(git branch --show-current)'")
    # The host ships only the session's own branch (agent-xxxxxx or fxa-NNNN); the reflog
    # names it when the agent switched to a branch of its own.
    cur="$(git branch --show-current)" sess='^(agent-[a-z0-9]+|fxa-[0-9]+)$'
    if ! [[ "$cur" =~ $sess ]]; then
      start="$(git reflog --format=%gs 2>/dev/null | sed -n 's/^checkout: moving from \([^ ]*\) to .*/\1/p' | grep -E "$sess" | head -1)"
      problems+=("the checkout is on '$cur', but the host ships only the session branch${start:+ '$start'}. Move your work there with: git checkout -B ${start:-<the session branch>}, then write the handoff again")
    fi
    while IFS= read -r m; do
      [ -n "$m" ] && [ ! -f "${m#/workspace/}" ] && problems+=("media_paths names $m, which does not exist")
    done < <(jq -r '.media_paths[]' "$done_file")
    # STE in the PR text. A script can be wrong about style, so these never stop a ship (exit 3).
    while IFS= read -r m; do style+=("$m"); done < <(jq -r '.pr_title, "", .pr_body' "$done_file" \
      | bash "$(dirname "$0")/ste.sh" --skip-lines-of .github/PULL_REQUEST_TEMPLATE.md | sed 's/^ste: /PR text, STE: /')
  fi
fi

[ "${#problems[@]}" -eq 0 ] && [ "${#style[@]}" -eq 0 ] && { echo "handoff check: ok"; exit 0; }
printf 'handoff check: %s\n' ${problems[@]+"${problems[@]}"} ${style[@]+"${style[@]}"}
# 3: style only. The host asks for one rewrite and ships either way.
[ "${#problems[@]}" -eq 0 ] && exit 3
exit 1
