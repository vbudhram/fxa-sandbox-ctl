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

# gh_pr_approver <KEY>
#   Print the login of the last human who approved the PR, or nothing.
#
#   The reviewer who signed off owns the ticket afterwards, which is why this is
#   not jira_reporter_login: the reporter filed it, the approver accepted it.
#   Bots are skipped, because a copilot approval is not a sign-off.
#
#   Last approval wins when several people approved. On #21225 an l10n reviewer
#   approved the Fluent strings first and the code owner approved two hours
#   later; the second one is the one that unblocked the merge.
gh_pr_approver() {
  pipeline_require || return 1
  local key="${1:-}"; [ -n "$key" ] || { echo "ERROR: approver needs <KEY>" >&2; return 1; }
  local br; br="$(worktree_branch_for "$key")" || return 1
  gh pr list --repo "$PIPE_REPO_SLUG" --state all --head "$br" --json reviews 2>/dev/null \
    | jq -r '[ .[0].reviews[]?
               | select(.state == "APPROVED")
               | select(.author.login | test("\\[bot\\]$|copilot"; "i") | not)
               | .author.login ] | last // empty'
}

# gh_red_infra <KEY>
#   Exit 0 and print why when EVERY failing check on the key's open PR matches a
#   known repo-infrastructure signature from PIPE_INFRA_CHECKS
#   ("check-name=log-regex", comma separated). Exit 1 when any failure is
#   unexplained, so a real red check still reaches a human.
#
#   Cached per head sha in <KEY>.redinfra: the failing job's log is fetched once,
#   not on every pass. On 2026-09-17 the same l10n `extract` 401 was read three
#   times across three PRs before anyone wrote the pattern down.
gh_red_infra() {
  pipeline_require || return 1
  local key="${1:-}"; [ -n "$key" ] || return 1
  [ -n "${PIPE_INFRA_CHECKS:-}" ] || return 1
  local br; br="$(worktree_branch_for "$key")" || return 1
  local json; json="$(gh pr list --repo "$PIPE_REPO_SLUG" --state open --head "$br" \
    --json number,headRefOid,statusCheckRollup 2>/dev/null)" || return 1
  [ "$(printf '%s' "$json" | jq 'length')" -gt 0 ] || return 1
  local sha cache; sha="$(printf '%s' "$json" | jq -r '.[0].headRefOid')"
  cache="${PIPE_STATE_DIR}/${key}.redinfra"
  if [ -f "$cache" ] && [ "$(head -1 "$cache")" = "$sha" ]; then
    local hit; hit="$(sed -n '2p' "$cache")"
    [ -n "$hit" ] && { echo "$hit"; return 0; }
    return 1
  fi
  local fails; fails="$(printf '%s' "$json" | jq -r '.[0].statusCheckRollup[]
    | select(((.conclusion // .state) | ascii_upcase) as $c | $c=="FAILURE" or $c=="ERROR" or $c=="TIMED_OUT")
    | "\(.name // .context)\t\(.detailsUrl // .targetUrl // "")"')"
  [ -n "$fails" ] || return 1
  local name url rule cname cre run job matched why="" all=1 rules
  IFS=',' read -ra rules <<< "$PIPE_INFRA_CHECKS"
  while IFS=$'\t' read -r name url; do
    [ -n "$name" ] || continue
    matched=""
    for rule in "${rules[@]}"; do
      cname="${rule%%=*}"; cre="${rule#*=}"
      [ "$name" = "$cname" ] || continue
      run="$(printf '%s' "$url" | grep -oE 'runs/[0-9]+' | cut -d/ -f2 || true)"
      job="$(printf '%s' "$url" | grep -oE 'job/[0-9]+' | cut -d/ -f2 || true)"
      if [ -n "$run" ] && [ -n "$job" ] \
         && gh run view "$run" --repo "$PIPE_REPO_SLUG" --job "$job" --log-failed 2>/dev/null | grep -qE "$cre"; then
        matched="${name}(${cre})"
      fi
    done
    if [ -n "$matched" ]; then why="${why}${why:+, }${matched}"; else all=0; fi
  done <<< "$fails"
  { echo "$sha"; if [ "$all" = 1 ]; then echo "$why"; else echo ""; fi; } > "$cache"
  [ "$all" = 1 ] && [ -n "$why" ] && { echo "$why"; return 0; }
  return 1
}

# gh_gate_stuck <KEY> [MIN-AGE-SECONDS]
#   Exit 0 when the PR's only pending checks are the CircleCI functional-tests
#   approval gate (and the workflow that waits on it), and the head commit is
#   older than MIN-AGE-SECONDS (default 600). Pass 0 to approve a fresh push. That is a launcher that died between `gh pr create` and
#   finish_approve_functional_gate: nothing else re-approves the gate, so the
#   PR would show one pending check forever. Prints the PR url.
gh_gate_stuck() {
  pipeline_require || return 1
  local key="${1:-}"; [ -n "$key" ] || return 1
  local br; br="$(worktree_branch_for "$key")" || return 1
  gh pr list --repo "$PIPE_REPO_SLUG" --state open --head "$br" \
    --json url,statusCheckRollup,commits 2>/dev/null \
  | jq -er --argjson now "$(date +%s)" --argjson age "${2:-600}" '
      .[0] // empty
      | [ .statusCheckRollup[]
          | select(((.status // .state) | ascii_upcase) as $s | $s == "PENDING" or $s == "IN_PROGRESS" or $s == "QUEUED")
          | (.name // .context) ] as $pending
      | select(($pending | length) > 0)
      | select($pending | all(test("Approve Functional Tests|^test_pull_request$")))
      | select($pending | any(test("Approve Functional Tests")))
      | select(($now - (.commits[-1].committedDate | fromdateiso8601)) > $age)
      | .url'
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
  jqx=".[] | (${_GH_ROLLUP_JQ}) as \$r | \"\(.headRefName) \(.number) \(.state) \(\$r.ok) \(\$r.fail) \(\$r.run) \(.mergeable)\""
  # `|| rc=$?` is load-bearing: with `set -e` a bare failing command
  # substitution kills the function before the guard below can fire.
  #
  # `mergeable` rides along in this same call for free. GitHub computes it
  # lazily and returns UNKNOWN for anything it has not computed yet, but the
  # request itself triggers the computation, so a second call resolves most of
  # them. Re-poll once rather than reporting a green PR that cannot merge.
  _gh_drain_fetch() {
    gh pr list --repo "$PIPE_REPO_SLUG" --state all --limit 200 \
      --json number,state,headRefName,statusCheckRollup,mergeable \
      -q "$jqx" 2>/dev/null
  }
  map="$(_gh_drain_fetch)" || rc=$?
  if [ "$rc" -eq 0 ] && printf '%s\n' "$map" | grep -q ' UNKNOWN$'; then
    sleep 2
    local remap
    remap="$(_gh_drain_fetch)" && [ -n "$remap" ] && map="$remap"
  fi
  unset -f _gh_drain_fetch
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
  local key br line num state ok bad run mrg
  for key in $keys; do
    br="$(worktree_branch_for "$key")"
    line="$(printf '%s\n' "$map" | awk -v b="$br" '$1 == b {print $2, $3, $4, $5, $6, $7; exit}')"
    if [ -z "$line" ]; then
      # Report a missing PR rather than relabelling: it is an anomaly worth a
      # human glance, not a merge.
      echo "$key none -"
      continue
    fi
    read -r num state ok bad run mrg <<<"$line"
    case "$state" in
      OPEN)
        # A `done` ticket is advertised as review-ready and nothing else re-reads
        # its checks, so a job that goes red AFTER the reconcile is invisible: on
        # 2026-08-25 #21073 had been red for six days while the report still
        # listed it as ready. Report it, never relabel it -- the cause is often
        # repo infrastructure rather than the PR.
        if [ "${bad:-0}" -gt 0 ]; then
          echo "$key $num RED ok=$ok fail=$bad running=$run"
        # A green PR that cannot merge is not review-ready, but nothing else
        # reads mergeability: the drain split only on PR state and on a red
        # check, so a conflict was invisible. On 2026-09-01 four of twelve
        # `done` PRs were CONFLICTING while the report advertised all twelve.
        # Conflicts are churn, not a backlog -- FXA-11871 went from clean to
        # conflicting inside two hours when two unrelated PRs merged.
        elif [ "$mrg" = "CONFLICTING" ]; then
          echo "$key $num CONFLICT"
        elif [ "$mrg" = "UNKNOWN" ]; then
          # Still uncomputed after a re-poll. Say so rather than call it clean.
          echo "$key $num CONFLICT? mergeability-uncomputed"
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
#   thumbsup        WRITE(PR): react 👍 to those ids a later push made outdated, then clear them
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
      [[ "$id" =~ ^[0-9]+$ ]] || { echo "$key not addressed: $id has no lines to check; react by hand if fixed"; continue; }
      # Recording an id is intent, not proof. Only a later commit that changed the
      # comment's lines shows the round fixed it. GitHub then nulls `line`; after a
      # force-push `position` can stay non-null, so it is not the signal.
      if [ "$(gh api "repos/${PIPE_REPO_SLUG}/pulls/comments/${id}" --jq '.line // "outdated"' 2>/dev/null)" != "outdated" ]; then
        echo "$key not addressed: comment $id lines unchanged, no reaction"; continue
      fi
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

  # Inline review comments, then PR conversation comments. A reviewer's "do not
  # port this, remove it instead" lands in the conversation, not on a diff line,
  # and until 2026-09-21 the pass never read that endpoint. Conversation ids
  # carry an `i` prefix so thumbsup knows which reactions endpoint to hit. The
  # pass's own 🤖 comments and bot chatter (CI links, Copilot summaries) are not
  # feedback.
  local all conv
  all="$(gh api "repos/${PIPE_REPO_SLUG}/pulls/${pr}/comments" --paginate 2>/dev/null \
         | jq -c '[.[] | select(.position != null)
                       | {id: (.id|tostring), author: .user.login, association: .author_association,
                          trusted: ((.author_association | IN("OWNER","MEMBER","COLLABORATOR")) or (.user.login | test("copilot";"i"))),
                          path, line: (.line // .original_line), body}]')"
  [ -n "$all" ] || all='[]'
  conv="$(gh api "repos/${PIPE_REPO_SLUG}/issues/${pr}/comments" --paginate 2>/dev/null \
         | jq -c '[.[] | select(.user.type != "Bot" and (.body | startswith("🤖") | not))
                       | {id: ("i" + (.id|tostring)), author: .user.login, association: .author_association,
                          trusted: (.author_association | IN("OWNER","MEMBER","COLLABORATOR")),
                          path: null, line: null, body}]')"
  [ -n "$conv" ] || conv='[]'
  all="$(jq -c -n --argjson a "$all" --argjson b "$conv" '$a + $b')"

  if [ "$sub" = "ack" ]; then
    printf '%s\n' "$all" | jq -r '.[].id' >>"$seen"
    sort -u -o "$seen" "$seen" 2>/dev/null || true
    echo "acked $(printf '%s\n' "$all" | jq 'length') comment(s) on #${pr}"
    return 0
  fi

  local seen_json
  seen_json="$( { cat "$seen" 2>/dev/null || true; } | jq -R 'select(length>0)' | jq -s '.')"
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
# gh_conflicts KEY
#   Which files conflict between origin/main and this ticket's branch, and what
#   kind of resolution they need. Prints "<class> <file>..." or nothing when the
#   branch merges clean.
#
#   `git merge-tree --write-tree` computes the merge in the object database: no
#   worktree, no checkout, no pool slot. So this is safe to run on every drain
#   line without touching the branch a live ticket has checked out.
#
#   Classes:
#     lockfile  only yarn.lock -- resolve by taking main's copy and reinstalling
#     source    any real file  -- needs an agent to read both sides
gh_conflicts() {
  pipeline_require || return 1
  local key="${1:-}"; [ -n "$key" ] || { echo "ERROR: conflicts needs <KEY>" >&2; return 1; }
  local br; br="$(worktree_branch_for "$key")" || return 1
  local repo="${PIPE_REPO:-$PWD}"

  git -C "$repo" fetch origin main "$br" -q 2>/dev/null || {
    echo "ERROR: cannot fetch origin/${br}" >&2; return 1; }

  local files
  files="$(git -C "$repo" merge-tree --write-tree --name-only \
             origin/main "origin/${br}" 2>/dev/null \
           | tail -n +2 | grep -vE '^(Auto-merging|CONFLICT|$)' || true)"
  [ -n "$files" ] || return 0

  local class="source"
  if ! printf '%s\n' "$files" | grep -qvE '(^|/)(yarn\.lock|package-lock\.json)$'; then
    class="lockfile"
  fi
  echo "$class $(printf '%s' "$files" | tr '\n' ' ')"
}

# gh_has_human_approval KEY
#   Exit 0 when a human has already reviewed this ticket's PR. A rebase
#   force-pushes, which dismisses a human review and rewrites history under
#   someone who may be mid-read. Bot reviewers do not count: copilot re-reviews
#   every push on its own, so nothing is lost by rebasing past it.
gh_has_human_approval() {
  pipeline_require || return 1
  local key="${1:-}"; [ -n "$key" ] || return 1
  local br; br="$(worktree_branch_for "$key")" || return 1
  local humans
  humans="$(gh pr list --repo "$PIPE_REPO_SLUG" --state open --head "$br" \
              --json reviews \
              -q '[.[0].reviews[]?.author.login
                   | select(test("(?i)(copilot|\\[bot\\]|-bot$)") | not)]
                  | unique | join(",")' 2>/dev/null)"
  [ -n "$humans" ] && { echo "$humans"; return 0; }
  return 1
}

gh_pr_states_json() {
  pipeline_require || return 1
  local keys="${1:-}"
  [ -n "$keys" ] || { echo '[]'; return 0; }
  local rollup meta rc=0
  rollup="$(gh pr list --repo "$PIPE_REPO_SLUG" --state all --limit 200 \
              --json number,state,headRefName,statusCheckRollup 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] && [ -n "$rollup" ] || { echo 'null'; return 0; }
  meta="$(gh pr list --repo "$PIPE_REPO_SLUG" --state all --limit 200 \
            --json number,headRefName,title,isDraft,reviewDecision,updatedAt,mergeable 2>/dev/null)" || rc=$?
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
           then {title: null, draft: null, review: null, updated: null, mergeable: null}
           else {title: $m.title, draft: $m.isDraft,
                 review: $m.reviewDecision, updated: $m.updatedAt,
                 mergeable: $m.mergeable}
           end))'
}

# ── GitHub App identity ────────────────────────────────────────
# The pipeline can act as a GitHub App instead of the operator: the bot authors
# the commit and the PR, GitHub signs the commit, and the operator's key and
# login never enter the push path. Active when GITHUB_APP_ID, GITHUB_APP_PEM,
# and GITHUB_APP_INSTALLATION_ID are all set.

github_app_enabled() {
  [ -n "${GITHUB_APP_ID:-}" ] && [ -n "${GITHUB_APP_PEM:-}" ] && [ -n "${GITHUB_APP_INSTALLATION_ID:-}" ]
}

# github_app_jwt
#   A 10-minute RS256 JWT for the app itself. Only the app endpoints take it.
github_app_jwt() {
  local b64='openssl base64 -A'
  local hdr pay now
  now="$(date +%s)"
  hdr="$(printf '{"alg":"RS256","typ":"JWT"}' | $b64 | tr '+/' '-_' | tr -d '=')"
  pay="$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' "$(( now - 60 ))" "$(( now + 540 ))" "$GITHUB_APP_ID" | $b64 | tr '+/' '-_' | tr -d '=')"
  printf '%s.%s.%s' "$hdr" "$pay" \
    "$(printf '%s.%s' "$hdr" "$pay" | openssl dgst -sha256 -sign "$GITHUB_APP_PEM" | $b64 | tr '+/' '-_' | tr -d '=')"
}

# github_app_installations
#   List where the app is installed: "<installation id>\t<account>". Used once,
#   to find GITHUB_APP_INSTALLATION_ID after the org approves the install.
github_app_installations() {
  curl -sf -H "Authorization: Bearer $(github_app_jwt)" -H "Accept: application/vnd.github+json" \
    https://api.github.com/app/installations \
  | jq -r '.[] | "\(.id)\t\(.account.login)\t\(.repository_selection)"'
}

# github_app_token
#   An installation token: what `gh` and git use to act as the bot. It lives 60
#   minutes, so mint it at handoff, never at launch. Cached for 50 minutes.
github_app_token() {
  local cache="${TMPDIR:-/tmp}/fxa-github-app-token.${GITHUB_APP_INSTALLATION_ID}"
  if [ -s "$cache" ] && [ "$(( $(date +%s) - $(stat -f %m "$cache") ))" -lt 3000 ]; then
    cat "$cache"; return 0
  fi
  local tok
  tok="$(curl -sf -X POST -H "Authorization: Bearer $(github_app_jwt)" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app/installations/${GITHUB_APP_INSTALLATION_ID}/access_tokens" | jq -r '.token // empty')"
  [ -n "$tok" ] || { echo "ERROR: could not mint a GitHub App installation token." >&2; return 1; }
  ( umask 077; printf '%s' "$tok" > "$cache" )
  printf '%s' "$tok"
}
