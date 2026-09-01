#!/bin/bash
# github.sh — PR state and review-comment reads for a pipeline.
#
# Nothing here merges or approves. Every write is either a 👍 reaction or a
# local bookkeeping file.
#
# Public API:
#   gh_pr_state KEY              "KEY <pr#> <state> ok=n fail=n running=n"
#   gh_drain KEYS                done keys whose PR is no longer open, or is red
#   gh_feedback KEY [sub] ...    unhandled review comments, and their bookkeeping

[ -n "${_FXA_GITHUB_LOADED:-}" ] && return 0
_FXA_GITHUB_LOADED=1

# Classify a statusCheckRollup into ok/fail/running counts. Both gh_pr_state and
# gh_drain use this, or the two commands would disagree about the same PR.
read -r -d '' _GH_ROLLUP_JQ <<'JQ' || true
[.statusCheckRollup[]? | (.conclusion // .state)] as $c
| { ok:   ($c | map(select(. == "SUCCESS")) | length),
    fail: ($c | map(select(. == "FAILURE" or . == "TIMED_OUT" or . == "ERROR")) | length),
    run:  ($c | map(select(. == "PENDING" or . == "IN_PROGRESS" or . == "QUEUED")) | length) }
JQ

gh_pr_state() {
  pipeline_require || return 1
  local key="${1:-}"; [ -n "$key" ] || { echo "ERROR: prstate needs <KEY>" >&2; return 1; }
  local br; br="$(worktree_branch_for "$key")" || return 1
  local json
  json="$(gh pr list --repo "$PIPE_REPO_SLUG" --state all --head "$br" \
            --json number,state,statusCheckRollup 2>/dev/null || echo '[]')"
  [ "$(printf '%s' "$json" | jq 'length')" -eq 0 ] && { echo "$key none - -"; return 0; }
  printf '%s' "$json" | jq -r --arg k "$key" "
    .[0] as \$p | (\$p | ${_GH_ROLLUP_JQ}) as \$r
    | \"\(\$k) \(\$p.number) \(\$p.state) ok=\(\$r.ok) fail=\(\$r.fail) running=\(\$r.run)\""
}

# gh_drain <KEYS>
#   Read-only. For each done key, print a line only when it needs action:
#   "KEY <pr#> MERGED|CLOSED" to leave `done`, or "KEY <pr#> RED ..." for a PR
#   that went red after the reconcile.
#
#   MERGED vs CLOSED matters. Filing both as merged made the archive claim the
#   pipeline landed work a reviewer had thrown away, and nothing else records
#   that outcome.
#
#   One `gh pr list` covers every ticket, so this costs the same for 3 done
#   tickets or 30.
gh_drain() {
  pipeline_require || return 1
  local keys="${1:-}"
  [ -n "$keys" ] || return 0
  local map jqx rc=0
  jqx=".[] | (${_GH_ROLLUP_JQ}) as \$r | \"\(.headRefName) \(.number) \(.state) \(\$r.ok) \(\$r.fail) \(\$r.run)\""
  # `|| rc=$?` is load-bearing: with `set -e` a bare failing command
  # substitution kills the function before the guard below can fire.
  map="$(gh pr list --repo "$PIPE_REPO_SLUG" --state all --limit 200 \
           --json number,state,headRefName,statusCheckRollup \
           -q "$jqx" 2>/dev/null)" || rc=$?
  # A failed fetch used to fall through to an empty map, which made EVERY done
  # key print `none -`. On 2026-08-25 that reported 12 simultaneous anomalies
  # from one transient `gh` hiccup; the next two runs were clean. A uniform
  # answer across every ticket is a tool failure, never 12 PRs vanishing at
  # once, so fail loudly instead of narrating a wrong one. The repo always has
  # open PRs, so an empty map is the same failure wearing a different hat.
  if [ "$rc" -ne 0 ] || [ -z "$map" ]; then
    echo "drain: gh pr list failed (exit $rc) -- refusing to report 'none' for $(printf '%s\n' "$keys" | grep -c .) done key(s)" >&2
    return 1
  fi
  local key br line num state ok bad run
  for key in $keys; do
    br="$(worktree_branch_for "$key")"
    line="$(printf '%s\n' "$map" | awk -v b="$br" '$1 == b {print $2, $3, $4, $5, $6; exit}')"
    if [ -z "$line" ]; then
      # Report a missing PR rather than relabelling: it is an anomaly worth a
      # human glance, not a merge.
      echo "$key none -"
      continue
    fi
    read -r num state ok bad run <<<"$line"
    case "$state" in
      OPEN)
        # A `done` ticket is advertised as review-ready and nothing else re-reads
        # its checks, so a job that goes red AFTER the reconcile is invisible: on
        # 2026-08-25 #21073 had been red for six days while the report still
        # listed it as ready. Report it, never relabel it -- the cause is often
        # repo infrastructure rather than the PR.
        if [ "${bad:-0}" -gt 0 ]; then
          echo "$key $num RED ok=$ok fail=$bad running=$run"
        fi
        ;;
      *) echo "$key $num $state" ;;   # MERGED or CLOSED
    esac
  done
  return 0
}

# gh_feedback <KEY> [sub] ...
#   (no sub)   list unhandled review comments as JSON
#   ack        mark every currently-open comment handled
#   rounds [bump]   read or increment the feedback-round counter
#   acted <id>...   WRITE(local): record the ids this round will fix
#   thumbsup        WRITE(PR): react 👍 to those ids, then clear them
#
# Two filters matter. `position: null` means the comment sits on a diff hunk
# that a later push replaced, so it is stale and acting on it edits code that
# moved. The seen-file holds comment IDs rather than a timestamp, because a
# reviewer can edit a comment in place and that must not resurrect it.
gh_feedback() {
  pipeline_require || return 1
  local key="${1:-}" sub="${2:-}"
  [ -n "$key" ] || { echo "ERROR: feedback needs <KEY>" >&2; return 1; }
  local br pr seen
  br="$(worktree_branch_for "$key")" || return 1
  seen="${PIPE_STATE_DIR}/${key}.feedback-seen"

  if [ "$sub" = "rounds" ]; then
    local f="${PIPE_STATE_DIR}/${key}.feedback-rounds" n
    n="$(cat "$f" 2>/dev/null || echo 0)"
    if [ "${3:-}" = "bump" ]; then n=$((n + 1)); echo "$n" >"$f"; fi
    echo "$n"; return 0
  fi

  # Record the comment IDs this round will actually FIX. A launch and its
  # reconcile happen in DIFFERENT passes, so this has to live on disk.
  # Judgment does not survive a cron-fired pass with no memory of the last one.
  if [ "$sub" = "acted" ]; then
    shift 2
    [ "$#" -gt 0 ] || { echo "ERROR: feedback <KEY> acted needs at least one comment id" >&2; return 1; }
    printf '%s\n' "$@" >>"${PIPE_STATE_DIR}/${key}.feedback-acted"
    sort -u -o "${PIPE_STATE_DIR}/${key}.feedback-acted" "${PIPE_STATE_DIR}/${key}.feedback-acted" 2>/dev/null || true
    echo "recorded $# id(s) for $key"
    return 0
  fi

  # React 👍 to the comments this round actually fixed, AFTER the fix is pushed.
  # Reacting is not the same as acking: `ack` covers every listed comment,
  # including the ones the pass declined on purpose, so reacting at ack time
  # would claim credit for work nobody did. The reactions API is idempotent --
  # a repeat POST returns 200 with the existing reaction -- so a re-run is safe.
  if [ "$sub" = "thumbsup" ]; then
    local f="${PIPE_STATE_DIR}/${key}.feedback-acted" id n=0
    [ -s "$f" ] || { echo "no recorded ids for $key"; return 0; }
    while read -r id; do
      [ -n "$id" ] || continue
      if gh api --method POST "repos/${PIPE_REPO_SLUG}/pulls/comments/${id}/reactions" \
           -f content='+1' >/dev/null 2>&1; then
        n=$((n + 1))
      else
        echo "$key thumbsup-failed on comment $id -- react by hand" >&2
      fi
    done <"$f"
    rm -f "$f"
    echo "thumbsup $n comment(s) on $key"
    return 0
  fi

  pr="$(gh pr list --repo "$PIPE_REPO_SLUG" --state all --head "$br" --json number \
          -q '.[0].number' 2>/dev/null)"
  [ -n "$pr" ] && [ "$pr" != "null" ] || { echo "no PR for $br" >&2; return 1; }

  local all
  all="$(gh api "repos/${PIPE_REPO_SLUG}/pulls/${pr}/comments" --paginate 2>/dev/null \
         | jq -c '[.[] | select(.position != null)
                       | {id, author: .user.login, path, line: (.line // .original_line), body}]')"
  [ -n "$all" ] || all='[]'

  if [ "$sub" = "ack" ]; then
    printf '%s\n' "$all" | jq -r '.[].id' >>"$seen"
    sort -u -o "$seen" "$seen" 2>/dev/null || true
    echo "acked $(printf '%s\n' "$all" | jq 'length') comment(s) on #${pr}"
    return 0
  fi

  local seen_json
  seen_json="$( { cat "$seen" 2>/dev/null || true; } | jq -R 'tonumber?' | jq -s '.')"
  printf '%s\n' "$all" | jq --argjson seen "$seen_json" --arg pr "$pr" \
    '{pr: ($pr|tonumber), comments: [.[] | select(.id as $i | ($seen | index($i)) == null)]}'
}

# Does this ticket have recorded ids waiting for a 👍?
gh_feedback_has_acted() {
  pipeline_require || return 1
  [ -s "${PIPE_STATE_DIR}/${1}.feedback-acted" ]
}

# gh_pr_states_json <KEYS>
#   PR number, state, title, draft and review status, and the check tally for
#   many keys. Prints a JSON array.
#
#   Two calls, not one. `statusCheckRollup` is by far the most expensive field,
#   and asking for it alongside title, isDraft and reviewDecision at limit 200
#   makes the GraphQL query large enough that GitHub cancels the stream
#   ("stream error: ... CANCEL; received from peer"). Splitting keeps each query
#   cheap: the rollup call is the one that already worked, and the metadata call
#   is small and fast. Both are still O(1) in the number of tickets.
#
#   Prints `null` when either fetch fails, which is different from `[]` (fetched
#   fine, no PRs). The dashboard must not draw "no PR" for every ticket because
#   one call hiccupped. Same guard as gh_drain, for the same reason.
gh_pr_states_json() {
  pipeline_require || return 1
  local keys="${1:-}"
  [ -n "$keys" ] || { echo '[]'; return 0; }
  local rollup meta rc=0
  rollup="$(gh pr list --repo "$PIPE_REPO_SLUG" --state all --limit 200 \
              --json number,state,headRefName,statusCheckRollup 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] && [ -n "$rollup" ] || { echo 'null'; return 0; }
  meta="$(gh pr list --repo "$PIPE_REPO_SLUG" --state all --limit 200 \
            --json number,headRefName,title,isDraft,reviewDecision,updatedAt 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] && [ -n "$meta" ] || { echo 'null'; return 0; }

  printf '%s\n' "$keys" | jq -R -s --argjson rollup "$rollup" --argjson meta "$meta" '
    (INDEX($rollup[]; .headRefName)) as $R
    | (INDEX($meta[];   .headRefName)) as $M
    | split("\n") | map(select(length > 0))
    | map(. as $k
      | ($k | ascii_downcase) as $br
      | $R[$br] as $p
      | $M[$br] as $m
      | {key: $k, branch: $br}
        + (if $p == null
           then {pr: null, state: null, ok: 0, fail: 0, running: 0}
           else ([$p.statusCheckRollup[]? | (.conclusion // .state)]) as $c
             | {pr: $p.number, state: $p.state,
                ok:      ($c | map(select(. == "SUCCESS")) | length),
                fail:    ($c | map(select(. == "FAILURE" or . == "TIMED_OUT" or . == "ERROR")) | length),
                running: ($c | map(select(. == "PENDING" or . == "IN_PROGRESS" or . == "QUEUED")) | length)}
           end)
        # `//` treats false as empty, so isDraft:false would become null.
        # Branch on the record instead of defaulting each field.
        + (if $m == null
           then {title: null, draft: null, review: null, updated: null}
           else {title: $m.title, draft: $m.isDraft,
                 review: $m.reviewDecision, updated: $m.updatedAt}
           end))'
}
