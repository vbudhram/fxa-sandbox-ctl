#!/bin/bash
# targets.sh: a thread holds a set of targets (a branch, and its PR when it has one), not one branch.
# The record's .targets[] holds each target and .current the index of the one the agent works on.
# The current target's live fields stay at the top level (branch, pr_url, review_pr, ...), so every
# reader and writer of those fields keeps working: targets[current] is only a copy, refreshed on read.
# An old record with no .targets reads as one target (migrate on read, no rewrite).
# Only a one-repo session has targets: a team stack keeps one branch for each tree (lib/trees.sh).

# The fields of a target that live at the top level while it is current.
TARGET_FIELDS="branch pr_url review_pr base_sha push_lease checkout checkout_author checkout_person checkout_admin target_path target_base"

# targets_json <key>   The targets, the current one read from the top level.
targets_json() {
  jq -c --arg key "$1" --arg repo "${PIPE_REPO_SLUG:-}" '
    (.current // 0 | tonumber? // 0) as $c | (.targets // []) as $t
    | (($t[$c] // {source: "boot", state: "open"}) + {repo: ($t[$c].repo // $repo), branch: ((.branch // "") | if . == "" then $key else . end),
        pr_url: (.pr_url // ""), review_pr: (.review_pr // ""), base_sha: (.base_sha // ""), push_lease: (.push_lease // ""),
        checkout: (.checkout // ""), checkout_author: (.checkout_author // ""), checkout_person: (.checkout_person // ""), checkout_admin: (.checkout_admin // ""),
        target_path: ((.target_path // "") | if . == "" then "/workspace" else . end), target_base: (.target_base // "")}) as $cur
    | if ($t | length) == 0 then [$cur] else $t | .[$c] = $cur end' "$(_session_file "$1")"
}

# targets_current <key>   The index of the current target.
targets_current() { jq -r '.current // 0' "$(_session_file "$1")" 2>/dev/null || echo 0; }

# target_find <key> <repo> <branch>   The index of the target on that branch, or nothing.
target_find() {
  targets_json "$1" | jq -r --arg r "$2" --arg b "$3" \
    'to_entries[] | select((.value.repo | ascii_downcase) == ($r | ascii_downcase) and .value.branch == $b) | .key' | head -1
}

# target_switch <key> <target json>   Make the target current: the one on that branch, else a new one.
#   The old current target keeps its fields in .targets; the new one's go to the top level. Prints its index.
target_switch() {
  local key="$1" t="$2" list idx
  list="$(targets_json "$key")" || return 1
  idx="$(jq -r --argjson n "$t" 'to_entries[] | select((.value.repo | ascii_downcase) == ($n.repo | ascii_downcase) and .value.branch == $n.branch) | .key' <<< "$list" | head -1)"
  if [ -z "$idx" ]; then idx="$(jq length <<< "$list")"; list="$(jq -c --argjson n "$t" '. + [{state: "open"} + $n]' <<< "$list")"; fi
  # shellcheck disable=SC2016  # jq variables
  _session_write "$key" '.targets = $l | .current = $i | . as $r
    | reduce ($f | split(" "))[] as $k ($r; .[$k] = (($l[$i][$k] // "") | tostring))' \
    --argjson l "$list" --argjson i "$idx" --arg f "$TARGET_FIELDS" || return 1
  echo "$idx"
}

# target_end <key> <pr url> <MERGED|CLOSED>   That PR's target ends. Prints how many targets stay open.
target_end() {
  local key="$1" list
  list="$(targets_json "$key" | jq -c --arg u "$2" --arg s "$(tr 'A-Z' 'a-z' <<< "$3")" \
    'map(if .pr_url == $u or .review_pr == $u then .state = $s else . end)')" || return 1
  # shellcheck disable=SC2016  # jq variables
  _session_write "$key" '.targets = $l' --argjson l "$list" || return 1
  jq '[.[] | select(.state == "open")] | length' <<< "$list"
}

# targets_carry <key> <from>   A resume keeps every open target of the session it resumes, after _task_carry
#   set the top level. A merged or closed PR drops its target. The new runner has only /workspace, so each
#   target loses its runner path: the current one boots there, and a switch makes the others again.
targets_carry() {
  local key="$1" from="$2" list keep="[]" i n u st cur
  [ "$(jq -r '(.targets // []) | length' "$(_session_file "$from")" 2>/dev/null)" -gt 1 ] 2>/dev/null || return 0
  list="$(targets_json "$from")" || return 0
  n="$(jq length <<< "$list")"
  for ((i = 0; i < n; i++)); do
    [ "$(jq -r --argjson i "$i" '.[$i].state' <<< "$list")" = open ] || continue
    u="$(jq -r --argjson i "$i" '.[$i] | if .pr_url != "" then .pr_url else .review_pr end' <<< "$list")"
    if [ -n "$u" ]; then st="$(gh pr view "$u" --json state -q .state 2>/dev/null || true)"; case "$st" in MERGED|CLOSED) continue ;; esac; fi
    keep="$(jq -c --argjson i "$i" --argjson l "$list" '. + [$l[$i] | .target_path = ""]' <<< "$keep")"
  done
  cur="$(jq -r --arg b "$(session_get "$key" branch)" '[to_entries[] | select(.value.branch == $b) | .key][0] // empty' <<< "$keep")"
  if [ -z "$cur" ]; then keep="$(jq -c --argjson c "$(targets_json "$key")" '$c + .' <<< "$keep")"; cur=0; fi
  [ "$(jq length <<< "$keep")" -gt 1 ] || return 0
  # shellcheck disable=SC2016  # jq variables
  _session_write "$key" '.targets = $l | .current = $i | .target_path = "" | .target_base = ($l[$i].target_base // "")
    | .checkout_admin = ($l[$i].checkout_admin // "")' --argjson l "$keep" --argjson i "$cur"
}

# Branch writer locks: one writer for each repo:branch, a thread ("thread:<channel>:<ts>") or a pipeline
# ticket ("ticket:<KEY>"). Sessions and the pipeline both run this controller, so both read SESSION_DIR.
BRANCH_LOCK_DIR="${FXA_BRANCH_LOCK_DIR:-${SESSION_DIR}/branch-locks}"
_branch_lock_file() { printf '%s/%s__%s' "$BRANCH_LOCK_DIR" "$(tr 'A-Z/' 'a-z_' <<< "$1")" "$(printf '%s' "$2" | tr '/' '~')"; }

# branch_lock_holder <repo> <branch>   The holder of the branch, or nothing.
branch_lock_holder() { cat "$(_branch_lock_file "$1" "$2")" 2>/dev/null || true; }

# branch_lock_take <repo> <branch> <holder> [move]   Become the branch's writer. Another holder refuses, with a
#   line that names it, unless move: then the lock moves, and the old holder prints on stdout to be told.
branch_lock_take() {
  local f old m; f="$(_branch_lock_file "$1" "$2")"; m="${f}.lock"
  mkdir -p "$BRANCH_LOCK_DIR" || return 1
  local n=0; until mkdir "$m" 2>/dev/null; do n=$((n + 1)); [ "$n" -lt 50 ] || { echo "ERROR: the lock for ${2} is busy" >&2; return 1; }; sleep 0.1; done
  old="$(cat "$f" 2>/dev/null || true)"
  if [ -n "$old" ] && [ "$old" != "$3" ] && [ "${4:-}" != move ]; then
    rmdir "$m"; echo "ERROR: ${2} has another writer: ${old}. Move it here first." >&2; return 1
  fi
  printf '%s\n' "$3" > "$f"; rmdir "$m"
  [ -z "$old" ] || [ "$old" = "$3" ] || printf '%s\n' "$old"
  return 0
}

# branch_lock_release <repo> <branch> <holder>   Only the holder releases.
branch_lock_release() {
  local f; f="$(_branch_lock_file "$1" "$2")"
  [ "$(cat "$f" 2>/dev/null)" = "$3" ] && rm -f "$f"
  return 0
}

# A team admin moves a live session onto another PR or branch of the team's work repo in plain words.
# The agent ends its turn with 'host: target <ref>'; the host checks the ref and the admin's own words of
# that turn (lib/turn-words.sh), never the agent's, then gives the target its own worktree on the runner.

# _target_branch_ok <name>   A branch name that is safe in git, API paths and the runner's shell.
_target_branch_ok() {
  [[ "$1" =~ ^[A-Za-z0-9._/@+-]+$ ]] && [[ "$1" != *..* ]] && [[ "$1" != -* ]] && git check-ref-format --branch "$1" >/dev/null 2>&1
}

# _target_parse <ref>   "slug|pr|N" or "slug|branch|name" (slug "" for this team's repo): a PR or branch
# link, owner/repo#N, #N, PR N, branch <name>, or a plain branch name.
_target_parse() {
  local t="$1" re='^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/(pull|tree)/(.+)$' n
  t="${t#"${t%%[![:space:]]*}"}"; t="${t%"${t##*[![:space:]]}"}"
  if [[ "$t" =~ $re ]]; then
    local s="${BASH_REMATCH[1]}" k="${BASH_REMATCH[2]}" r="${BASH_REMATCH[3]%/}"
    if [ "$k" = pull ]; then [[ "$r" =~ ^[0-9]+$ ]] || return 1; echo "${s}|pr|${r}"; return 0; fi
    _target_branch_ok "$r" && echo "${s}|branch|${r}"; return
  fi
  if [[ "$t" =~ ^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#([0-9]+)$ ]]; then echo "${BASH_REMATCH[1]}|pr|${BASH_REMATCH[2]}"; return 0; fi
  n="$(tr 'A-Z' 'a-z' <<< "$t")"
  if [[ "$n" =~ ^(pr\ *)?#?([0-9]+)$ ]]; then echo "|pr|${BASH_REMATCH[2]}"; return 0; fi
  [[ "$n" =~ ^branch\ + ]] && t="${t#* }" && t="${t#"${t%%[! ]*}"}"
  _target_branch_ok "$t" && echo "|branch|${t}"
}

# _target_resolve <slug> <pr|branch> <ref>   {url, head, sha, base, author, person} of an open, same-repo PR,
#   or of a branch with no open PR (url ""). Prints the reason and fails otherwise.
_target_resolve() {
  local slug="$1" kind="$2" ref="$3" info="" sha="" base u="https://github.com/${1}/pull/${3}"
  local f=url,state,headRefName,headRefOid,baseRefName,isCrossRepository,author
  local q='{url: (.url // $u), state, head: .headRefName, sha: .headRefOid, base: .baseRefName, fork: .isCrossRepository, author: .author.login, person: ((.author.is_bot // false) | not)}'
  if [ "$kind" = pr ]; then
    info="$(_retry gh pr view "$u" --json "$f" 2>/dev/null | jq -c --arg u "$u" "$q" 2>/dev/null)" && [ -n "$info" ] \
      || { echo "I could not find PR ${ref} in ${slug}"; return 1; }
  else
    info="$(_retry gh pr list -R "$slug" --head "$ref" --state open --json "$f" 2>/dev/null \
      | jq -c --arg u "" "map(select(.isCrossRepository | not))[0] // empty | ${q}" 2>/dev/null)" || { echo "I could not read the PRs of ${slug}"; return 1; }
    if [ -z "$info" ]; then
      sha="$(_retry gh api "repos/${slug}/branches/${ref}" -q .commit.sha 2>/dev/null)" || { echo "${slug} has no branch ${ref}"; return 1; }
      base="$(_retry gh repo view "$slug" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)" || { echo "I could not read ${slug}"; return 1; }
      info="$(jq -nc --arg h "$ref" --arg s "$sha" --arg b "$base" '{url: "", state: "OPEN", head: $h, sha: $s, base: $b, fork: false, author: "", person: true}')"
    fi
  fi
  [ "$(jq -r .state <<< "$info")" = OPEN ] || { echo "$(jq -r .url <<< "$info") is not open"; return 1; }
  # A fork's CLAUDE.md, rules and skills would reach the agent, and the App cannot push there.
  [ "$(jq -r .fork <<< "$info")" != true ] || { echo "$(jq -r .url <<< "$info") is from a fork. Ask for a PR from a branch of ${slug} instead"; return 1; }
  _target_branch_ok "$(jq -r .head <<< "$info")" || { echo "$(jq -r .url <<< "$info") has a branch name I cannot use"; return 1; }
  [[ "$(jq -r .sha <<< "$info")" =~ ^[0-9a-f]{40}$ ]] || { echo "I could not read the head of ${ref}"; return 1; }
  jq -c 'del(.state, .fork)' <<< "$info"
}

# _target_never <slug> <branch> <has PR>   The host never writes a default, protected or release branch, or
#   the base of an open PR. A branch with no PR is one the agent made (agent-*). Fails closed on a read error.
_target_never() {
  local slug="$1" b="$2" d p n
  [[ "$b" =~ ^(main|master|develop|train-.*|release.*|stable.*)$ ]] && { echo "${b} is a default or release branch"; return 0; }
  [ -n "$3" ] || [[ "$b" == agent-* ]] || { echo "${b} has no open PR, and I only start a PR from a branch I made (agent-*)"; return 0; }
  d="$(_retry gh repo view "$slug" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)" || { echo "I could not read ${slug}"; return 0; }
  [ "$d" != "$b" ] || { echo "${b} is the default branch of ${slug}"; return 0; }
  p="$(_retry gh api "repos/${slug}/branches/${b}" -q .protected 2>/dev/null)" || { echo "I could not read branch ${b}"; return 0; }
  [ "$p" != true ] || { echo "${b} is a protected branch"; return 0; }
  n="$(_retry gh pr list -R "$slug" --base "$b" --state open --limit 1 --json number -q length 2>/dev/null)" || { echo "I could not read the PRs of ${slug}"; return 0; }
  [ "${n:-0}" = 0 ] || { echo "${b} is the base of an open PR"; return 0; }
  return 1
}

# _target_worktree <key> <head> <sha> <path>   On the runner: <sha> (a bundle from the host clone when the
#   runner lacks it) checked out as branch <head> in its own worktree. /workspace is not touched.
_target_worktree() {
  local key="$1" head="$2" sha="$3" at="$4" name root d qh qa
  name="$(worktree_branch_for "$key")"; qh="$(printf '%q' "$head")"; qa="$(printf '%q' "$at")"
  if ! _session_sh "$name" "git -C /workspace cat-file -e ${sha}^{commit}" >/dev/null 2>&1; then
    pipeline_ensure_clone >/dev/null 2>&1 && root="$(worktree_repo_root)" || { echo "I could not reach the repo's clone"; return 1; }
    _retry git -C "$root" fetch -q origin "+refs/heads/${head}:refs/remotes/origin/${head}" >/dev/null 2>&1 || { echo "I could not fetch ${head}"; return 1; }
    [ "$(git -C "$root" rev-parse -q --verify "refs/remotes/origin/${head}")" = "$sha" ] || { echo "${head} moved while I read it. Ask again"; return 1; }
    d="$(mktemp -d)"
    { git -C "$root" bundle create "${d}/target.bundle" "refs/remotes/origin/${head}" --not "$(session_get "$key" base_sha)" >/dev/null 2>&1 \
        || git -C "$root" bundle create "${d}/target.bundle" "refs/remotes/origin/${head}" >/dev/null 2>&1; } \
      && COPYFILE_DISABLE=1 tar -czf "${d}/t.tgz" -C "$d" target.bundle && vm_put "$name" "${d}/t.tgz" /home/agent/.fxa-target \
      || { rm -rf "$d"; echo "I could not send ${head} to the sandbox"; return 1; }
    rm -rf "$d"
  fi
  _session_sh "$name" "cd /workspace && { git cat-file -e ${sha}^{commit} 2>/dev/null || git fetch -q /home/agent/.fxa-target/target.bundle; } \
    && { [ -e ${qa}/.git ] || git -c core.hooksPath=/dev/null worktree add -q -f -B ${qh} ${qa} ${sha}; } && rm -rf /home/agent/.fxa-target" >/dev/null 2>&1 \
    || { echo "the sandbox could not take ${head}"; return 1; }
}

# session_target <key> <ref>   The agent's 'host: target <ref>' for the turn that just ended. Prints one
#   line for the thread; fails, with nothing moved, when the ref or the words do not hold.
session_target() {
  local key="$1" ref="$2" p slug kind n info url head sha base who h idx path old th
  trees_on "$key" && { echo "I did not switch: this session has several repos, and each keeps its own branch."; return 1; }
  [ "${PIPE_PR_OPEN:-1}" != 0 ] || { echo "I did not switch: this team is read-only, so I push nowhere."; return 1; }
  p="$(_target_parse "$ref")" || { echo "I did not switch: \"${ref:0:80}\" is not a PR or a branch."; return 1; }
  IFS='|' read -r slug kind n <<< "$p"; slug="${slug:-${PIPE_REPO_SLUG:-}}"
  [ -n "$slug" ] && [ "$(tr 'A-Z' 'a-z' <<< "$slug")" = "$(tr 'A-Z' 'a-z' <<< "${PIPE_REPO_SLUG:-}")" ] \
    || { echo "I did not switch: ${slug:-that repo} is not this team's work repo (${PIPE_REPO_SLUG:-none})."; return 1; }
  info="$(_target_resolve "$slug" "$kind" "$n")" || { echo "I did not switch: ${info}."; return 1; }
  url="$(jq -r .url <<< "$info")" head="$(jq -r .head <<< "$info")" sha="$(jq -r .sha <<< "$info")" base="$(jq -r .base <<< "$info")"
  local label="${url:-branch ${head}}"
  # The admin's own words of this turn must name it exactly: the agent read PR text, logs and Jira.
  local -a toks=("branch ${head}"); [[ "$head" =~ [-/0-9] ]] && toks+=("$head")
  [ -z "$url" ] || toks+=("$url" "${slug}#${url##*/}" "#${url##*/}" "pr ${url##*/}" "pr #${url##*/}")
  who="$(words_match "$key" "$(words_turn "$key")" target "${toks[@]}")" \
    || { echo "I did not switch to ${label}: only a team admin can move this session, in their own message that names it. Ask one to say it here."; return 1; }
  who="${who%% *}"
  if h="$(_target_never "$slug" "$head" "$url")"; then echo "I did not switch to ${label}: ${h}."; return 1; fi
  idx="$(target_find "$key" "$slug" "$head")"
  [ "$idx" != "$(targets_current "$key")" ] || { echo "This work is already on ${label}."; return 0; }
  path=""; [ -z "$idx" ] || path="$(targets_json "$key" | jq -r --argjson i "$idx" '.[$i].target_path // ""')"
  [ -n "$path" ] || path="/home/agent/targets/$(tr '/' '_' <<< "$head")"
  th="$(session_get "$key" thread)"; th="${th:+thread:${th}}"
  old="$(branch_lock_take "$slug" "$head" "${th:-session:${key}}" move 2>&1)" || { echo "I did not switch to ${label}: ${old}."; return 1; }
  [ "$path" = /workspace ] || h="$(_target_worktree "$key" "$head" "$sha" "$path")" || { echo "I did not switch to ${label}: ${h}."; return 1; }
  if [ -n "$idx" ]; then target_switch "$key" "$(targets_json "$key" | jq -c --argjson i "$idx" --arg p "$path" '.[$i] | .target_path = $p')" >/dev/null
  else target_switch "$key" "$(jq -nc --arg r "$slug" --arg b "$head" --arg u "$url" --arg s "$sha" --arg a "$(jq -r .author <<< "$info")" \
      --arg pp "$(jq -r 'if .person then "1" else "0" end' <<< "$info")" --arg w "$who" --arg p "$path" --arg tb "$base" \
      '{repo: $r, branch: $b, pr_url: $u, review_pr: $u, base_sha: $s, push_lease: $s, checkout: (if $u != "" then $u else "https://github.com/\($r)/tree/\($b)" end),
        checkout_author: $a, checkout_person: $pp, checkout_admin: $w, target_path: $p, target_base: $tb, source: "checkout"}')" >/dev/null
  fi || { echo "I did not switch to ${label}: I could not save the session."; return 1; }
  [ -z "$url" ] || session_set "$key" pr_announced 1
  # shellcheck disable=SC2016  # jq variables
  _session_write "$key" '.target_log = ((.target_log // []) + [{at: now, by: $w, to: $b, pr: $u, took_from: $o}])' \
    --arg w "$who" --arg b "$head" --arg u "$url" --arg o "$old" || true
  _session_history_add "$key" action "Switched to ${label} for ${who}${old:+, from ${old}}"
  [ -z "$url" ] || ! _thread_ok "${th#thread:}" || thread_set "${th#thread:}" pr_url "$url" pr_session "$key" branch "$head"
  # The agent goes on at once, in the target's worktree.
  printf '%s\n\n' "(Host: you now work on ${label}, branch ${head}, in ${path}. Finish the ask there: cherry-pick or rebase your commits from the earlier target. 'ship: pr' updates this target.)" >> "${SESSION_DIR}/${key}.queue"
  echo "This work is now on ${label}, as a team admin asked."
}

# targets_events <key> <events JSON>   At a turn's end, once: each 'host: target' line done, as a target
#   event before the turn end. A refusal drops the turn's ship line, so no change goes to the wrong PR.
targets_events() {
  local key="$1" ev="$2" ref text ok
  while IFS= read -r ref; do
    ok=true; text="$(session_target "$key" "$ref" 2>/dev/null)" || ok=false
    ev="$(jq -c --arg t "$text" --argjson ok "$ok" --arg u "$(session_get "$key" pr_url)" --arg b "$(session_get "$key" branch)" --arg c "$(targets_current "$key")" '
      (map(.type) | index("turn_end")) as $i
      | ({type: "target", ok: $ok, text: $t} + (if $ok then {url: $u, branch: $b, current: ($c | tonumber)} else {} end)) as $r
      | (if $ok then . else map(if .type == "turn_end" then del(.ship) else . end) end)
      | .[:$i] + [$r] + .[$i:]' <<< "$ev")"
  done < <(jq -r '.[] | select(.type == "turn_end") | (.asks // [])[] | select(test("^target\\s")) | sub("^target\\s+"; "")' <<< "$ev" | head -3)
  printf '%s\n' "$ev"
}
