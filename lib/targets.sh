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
