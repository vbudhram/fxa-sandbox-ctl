#!/bin/bash
# github.sh: PR state and review-comment reads for a pipeline.
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

# Classify a statusCheckRollup into ok/fail/running counts. Every PR read uses
# this one copy, or two commands would disagree about the same PR.
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
#   Print the login of the last human who approved the PR, or nothing. The
#   approver owns the ticket after the merge, not the reporter. Bots do not count.
#   The last approval wins: an l10n reviewer often approves first, and the code
#   owner's later approval is the one that unblocks the merge.
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
#   Cached per head sha in <KEY>.redinfra, so the failing job's log is fetched
#   once, not on every pass.
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
  local name url rule cname cre run job matched why="" all=1 rules log unread=0
  IFS=',' read -ra rules <<< "$PIPE_INFRA_CHECKS"
  while IFS=$'\t' read -r name url; do
    [ -n "$name" ] || continue
    matched=""
    for rule in "${rules[@]}"; do
      cname="${rule%%=*}"; cre="${rule#*=}"
      [ "$name" = "$cname" ] || continue
      run="$(printf '%s' "$url" | grep -oE 'runs/[0-9]+' | cut -d/ -f2 || true)"
      job="$(printf '%s' "$url" | grep -oE 'job/[0-9]+' | cut -d/ -f2 || true)"
      [ -n "$run" ] && [ -n "$job" ] || continue
      # Do not cache a failed fetch as "no match", or a known failure reads RED for the whole sha.
      if ! log="$(gh run view "$run" --repo "$PIPE_REPO_SLUG" --job "$job" --log-failed 2>/dev/null)"; then
        unread=1; continue
      fi
      printf '%s' "$log" | grep -qE "$cre" && matched="${name}(${cre})"
    done
    if [ -n "$matched" ]; then why="${why}${why:+, }${matched}"; else all=0; fi
  done <<< "$fails"
  [ "$unread" = 0 ] || return 1
  { echo "$sha"; if [ "$all" = 1 ]; then echo "$why"; else echo ""; fi; } > "$cache"
  [ "$all" = 1 ] && [ -n "$why" ] && { echo "$why"; return 0; }
  return 1
}

# gh_gate_stuck <KEY> [MIN-AGE-SECONDS]
#   Exit 0 when the PR's only pending checks are the CircleCI functional-tests
#   approval gate (and the workflow that waits on it), and the head commit is
#   older than MIN-AGE-SECONDS (default 600, pass 0 for a fresh push). This is a
#   launcher that died before it approved the gate. Nothing else approves it, so
#   the PR would show one pending check forever. Prints the PR url.
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
#   Keep MERGED and CLOSED apart, or the archive claims rejected work landed.
#   One `gh pr list` covers every ticket, so the cost does not grow with the count.
gh_drain() {
  pipeline_require || return 1
  local keys="${1:-}"
  [ -n "$keys" ] || return 0
  local map jqx rc=0
  jqx=".[] | (${_GH_ROLLUP_JQ}) as \$r | \"\(.headRefName) \(.number) \(.state) \(\$r.ok) \(\$r.fail) \(\$r.run) \(.mergeable)\""
  # `|| rc=$?` keeps `set -e` from killing the function before the guard below.
  # GitHub computes `mergeable` lazily and says UNKNOWN until then, but the
  # request starts the computation, so one re-poll resolves most of them.
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
  # A failed or empty fetch would make every done key print `none -`. The repo
  # always has PRs, so treat both as a tool failure, not as PRs that vanished.
  if [ "$rc" -ne 0 ] || [ -z "$map" ]; then
    echo "drain: gh pr list failed (exit $rc) -- refusing to report 'none' for $(printf '%s\n' "$keys" | grep -c .) done key(s)" >&2
    return 1
  fi
  local key br line num state ok bad run mrg
  for key in $keys; do
    br="$(worktree_branch_for "$key")"
    line="$(printf '%s\n' "$map" | awk -v b="$br" '$1 == b {print $2, $3, $4, $5, $6, $7; exit}')"
    if [ -z "$line" ]; then
      # Report a missing PR, do not relabel it: a human must look.
      echo "$key none -"
      continue
    fi
    read -r num state ok bad run mrg <<<"$line"
    case "$state" in
      OPEN)
        # Nothing else re-reads a done PR's checks or mergeability, so report
        # them here. Never relabel: the cause is often repo infrastructure.
        if [ "${bad:-0}" -gt 0 ]; then
          echo "$key $num RED ok=$ok fail=$bad running=$run"
        elif [ "$mrg" = "CONFLICTING" ]; then
          echo "$key $num CONFLICT"
        elif [ "$mrg" = "UNKNOWN" ]; then
          # Still uncomputed after the re-poll, so do not call it clean.
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

  # On disk, because the launch and its reconcile run in different passes.
  if [ "$sub" = "acted" ]; then
    shift 2
    [ "$#" -gt 0 ] || { echo "ERROR: feedback <KEY> acted needs at least one comment id" >&2; return 1; }
    local acted="${PIPE_STATE_DIR}/${key}.feedback-acted"
    printf '%s\n' "$@" >>"$acted"
    sort -u -o "$acted" "$acted" 2>/dev/null || true
    echo "recorded $# id(s) for $key"
    return 0
  fi

  # React only after the fix is pushed, never at ack time: `ack` also covers
  # comments the pass declined. The reactions API is idempotent, so a re-run is safe.
  if [ "$sub" = "thumbsup" ]; then
    local f="${PIPE_STATE_DIR}/${key}.feedback-acted" id n=0
    [ -s "$f" ] || { echo "no recorded ids for $key"; return 0; }
    while read -r id; do
      [[ "$id" =~ ^[0-9]+$ ]] || { echo "$key not addressed: $id has no lines to check; react by hand if fixed"; continue; }
      # A recorded id is intent, not proof. GitHub nulls `line` when a commit changes
      # those lines; `position` can stay set after a force-push, so it is no signal.
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

  # Inline comments, then conversation comments, where reviewers often put the
  # big asks. The `i` id prefix tells the endpoints apart. Our own 🤖 comments
  # and bot chatter are not feedback.
  local all conv
  all="$(gh api "repos/${PIPE_REPO_SLUG}/pulls/${pr}/comments" --paginate 2>/dev/null \
         | jq -c '[.[] | select(.position != null)
                       | {id: (.id|tostring), author: .user.login, association: .author_association,
                          trusted: ((.author_association | IN("OWNER","MEMBER","COLLABORATOR")) or (.user.type == "Bot" and (.user.login | IN("Copilot","copilot-pull-request-reviewer[bot]")))),
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

  _retry git -C "$repo" fetch origin main "$br" -q 2>/dev/null || {
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

# gh_relock KEY
#   Fix a conflict that is only yarn.lock, with no agent and no force-push. In a
#   throwaway detached worktree: merge origin/main, take main's yarn.lock, let
#   yarn re-resolve the branch's own dependency changes, commit the merge, and
#   push it as a fast-forward. History is not rewritten.
#   PIPE_RELOCK_CMD overrides the resolver (tests stub it).
gh_relock() {
  pipeline_require || return 1
  local key="${1:-}"; [ -n "$key" ] || { echo "ERROR: relock needs <KEY>" >&2; return 1; }
  local br repo conf n wt rc=0
  br="$(worktree_branch_for "$key")" || return 1
  repo="${PIPE_REPO:-$PWD}"

  conf="$(gh_conflicts "$key")" || return 1
  case "$conf" in
    "") echo "${key} merges clean; nothing to relock." >&2; return 0 ;;
    lockfile\ *) ;;
    *) echo "ERROR: ${key} conflicts outside the lockfile (${conf}); it needs a rebase round." >&2; return 1 ;;
  esac
  n="$(pipeline_attempts "$key")"
  if [ "${n:-0}" -ge 2 ]; then
    echo "ERROR: ${key} has ${n} attempts recorded; the cap is 2." >&2; return 1
  fi

  wt="$(mktemp -d "${TMPDIR:-/tmp}/relock-${br}.XXXXXX")"
  # Hooks off: the repo's post-checkout hook clones l10n into every new worktree.
  git -C "$repo" -c core.hooksPath=/dev/null worktree add -q --detach "$wt" "origin/${br}" >&2 || {
    rm -rf "$wt"; return 1; }
  (
    set -e
    cd "$wt"
    git -c core.hooksPath=/dev/null merge -q --no-edit origin/main >/dev/null 2>&1 || true
    locks="$(git diff --name-only --diff-filter=U)"
    [ -n "$locks" ] || { echo "ERROR: the merge left no conflicted paths." >&2; exit 1; }
    if printf '%s\n' "$locks" | grep -qvE '(^|/)yarn\.lock$'; then
      echo "ERROR: the merge conflicts outside yarn.lock: $(printf '%s ' $locks)" >&2; exit 1
    fi
    # In a merge of main into the branch, "theirs" is main.
    printf '%s\n' "$locks" | xargs git checkout --theirs --
    ${PIPE_RELOCK_CMD:-yarn install --mode=update-lockfile} >&2
    printf '%s\n' "$locks" | xargs git add --
    git -c core.hooksPath=/dev/null commit -q --no-edit ${PIPE_RELOCK_SIGN--S}
    git push -q origin "HEAD:refs/heads/${br}" >&2
  ) || rc=1
  git -C "$repo" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
  [ "$rc" = 0 ] || return 1
  pipeline_attempts "$key" bump >/dev/null
  echo "${key}: merged origin/main and re-resolved yarn.lock; pushed ${br}."
}

# gh_pr_states_json <KEYS>
#   PR number, state, title, draft and review status, and the check tally for
#   many keys, as a JSON array. One call per ticket branch, 8 at a time: the
#   pipeline's own PRs only. Listing the repo's 200 latest PRs instead took
#   about 45 s of each dashboard refresh. Prints `null` when a fetch fails, so
#   the dashboard does not draw "no PR" for every ticket.
gh_pr_states_json() {
  pipeline_require || return 1
  local keys="${1:-}"
  [ -n "$keys" ] || { echo '[]'; return 0; }
  local dir; dir="$(mktemp -d)"
  # The newest PR of each branch, with every field below. A branch is the key in
  # lower case: a plain git name, so it is safe as an argument.
  printf '%s\n' "$keys" | tr '[:upper:]' '[:lower:]' | grep -E '^[a-z][a-z0-9]*-[0-9]+$' | xargs -P 8 -I{} sh -c '
    gh pr list --repo "$1" --head "$2" --state all --limit 1 \
      --json number,state,headRefName,statusCheckRollup,title,isDraft,reviewDecision,updatedAt,mergeable,createdAt,reviewRequests,latestReviews \
      > "$3/$2.json" 2>/dev/null || : > "$3/$2.fail"' _ "$PIPE_REPO_SLUG" {} "$dir"
  if ls "$dir"/*.fail >/dev/null 2>&1; then rm -rf "$dir"; echo 'null'; return 0; fi
  # Files, not --argjson: with latestReviews the payload can pass ARG_MAX.
  local tr tm; tr="$(mktemp)"; tm="$tr"
  cat "$dir"/*.json 2>/dev/null | jq -s 'add // []' > "$tr"; rm -rf "$dir"
  printf '%s\n' "$keys" | jq -R -s --slurpfile rollup "$tr" --slurpfile meta "$tm" '
    (INDEX($rollup[0][]; .headRefName)) as $R
    | (INDEX($meta[0][];   .headRefName)) as $M
    | split("\n") | map(select(length > 0))
    | map(. as $k
      | ($k | ascii_downcase) as $br
      | $R[$br] as $p
      | $M[$br] as $m
      | {key: $k, branch: $br}
        + (if $p == null
           then {pr: null, state: null, ok: 0, fail: 0, running: 0}
           else ($p | '"${_GH_ROLLUP_JQ}"') as $r
             | {pr: $p.number, state: $p.state, ok: $r.ok, fail: $r.fail, running: $r.run}
           end)
        # `//` treats false as empty, so isDraft:false would become null.
        # Branch on the record instead of defaulting each field.
        + (if $m == null
           then {title: null, draft: null, review: null, updated: null, mergeable: null,
                 created: null, reviewers: null, last_human_review: null}
           # updatedAt moves on every bot and CI event, so review age reads the
           # last human review instead; bots never count as a reviewer.
           else ([$m.latestReviews[]? | select(.author.login | test("\\[bot\\]$|copilot"; "i") | not)]
                 | max_by(.submittedAt)) as $h
             | {title: $m.title, draft: $m.isDraft,
                 review: $m.reviewDecision, updated: $m.updatedAt,
                 mergeable: $m.mergeable, created: $m.createdAt,
                 reviewers: [$m.reviewRequests[]? | (.login // .slug // .name) | select(. != null)],
                 last_human_review: (if $h == null then null
                                     else {login: $h.author.login, state: $h.state, at: $h.submittedAt} end)}
           end))'
  rm -f "$tr" "$tm"
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
_gh_b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

github_app_jwt() {
  local hdr pay now
  now="$(date +%s)"
  hdr="$(printf '{"alg":"RS256","typ":"JWT"}' | _gh_b64url)"
  pay="$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' "$(( now - 60 ))" "$(( now + 540 ))" "$GITHUB_APP_ID" | _gh_b64url)"
  printf '%s.%s.%s' "$hdr" "$pay" \
    "$(printf '%s.%s' "$hdr" "$pay" | openssl dgst -sha256 -sign "$GITHUB_APP_PEM" | _gh_b64url)"
}

# github_app_token
#   An installation token: what `gh` and git use to act as the bot. It lives 60
#   minutes, so mint it at handoff, never at launch. Cached for 50 minutes.
github_app_token() {
  local cache="${TMPDIR:-/tmp}/fxa-github-app-token.${GITHUB_APP_INSTALLATION_ID}"
  if [ -s "$cache" ] && [ "$(( $(date +%s) - $(_mtime "$cache") ))" -lt 3000 ]; then
    cat "$cache"; return 0
  fi
  local tok
  tok="$(curl -sf --retry 3 --retry-connrefused --max-time 30 -X POST -H "Authorization: Bearer $(github_app_jwt)" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app/installations/${GITHUB_APP_INSTALLATION_ID}/access_tokens" | jq -r '.token // empty')"
  [ -n "$tok" ] || { echo "ERROR: could not mint a GitHub App installation token." >&2; return 1; }
  ( umask 077; printf '%s' "$tok" > "$cache" )
  printf '%s' "$tok"
}

# _gh_app_api <METHOD> <path>
#   Call the REST API as the App with the JSON body on stdin. The token goes in a
#   0600 header file, not argv, so `ps` never shows it.
_gh_app_api() {
  local hdr tok rc=0
  # GitHub's 5xx and resets are transient. Blobs, trees, commits and reads are
  # safe to repeat; a ref write is not, and its caller checks the result.
  local -a retry=(--retry 3 --retry-connrefused --max-time 60)
  case "$1 $2" in "POST git/refs"|"PATCH git/refs/"*) retry=(--max-time 60) ;; esac
  tok="$(github_app_token)" || return 1
  hdr="$(mktemp)"; chmod 600 "$hdr"
  printf 'Authorization: Bearer %s\nAccept: application/vnd.github+json\n' "$tok" > "$hdr"
  curl -sS --fail-with-body "${retry[@]}" -X "$1" -H @"$hdr" --data-binary @- "https://api.github.com/repos/${PIPE_REPO_SLUG}/$2" || rc=$?
  rm -f "$hdr"
  return "$rc"
}

# _gh_app_ref_is <branch> <sha>   A ref write is not retried: when one fails,
# the branch may still have moved, so read it back.
_gh_app_ref_is() { [ "$(printf '' | _gh_app_api GET "git/ref/heads/$1" 2>/dev/null | jq -r '.object.sha // empty')" = "$2" ]; }

# github_app_commit <worktree> <branch> <parent_sha> <message>
#   Create the staged change as one commit through the API, so the App is its
#   author and GitHub signs it, then move <branch> to it. An existing branch must
#   still be where our tracking ref says (the --force-with-lease rule). Resets the
#   slot onto the new commit and prints its sha.
github_app_commit() {
  local wt="$1" branch="$2" parent="$3" msg="$4"
  local st path mode sha entries='[]' tree commit remote expect
  while IFS= read -r -d '' st && IFS= read -r -d '' path; do
    if [ "$st" = D ]; then
      entries="$(jq -c --arg p "$path" '. + [{path: $p, mode: "100644", type: "blob", sha: null}]' <<< "$entries")"
      continue
    fi
    read -r mode sha _ < <(git -C "$wt" ls-files -s -- "$path")
    sha="$(git -C "$wt" cat-file blob "$sha" | base64 | tr -d '\n' | jq -Rc '{content: ., encoding: "base64"}' \
           | _gh_app_api POST git/blobs | jq -r '.sha // empty')"
    [ -n "$sha" ] || { echo "ERROR: could not upload ${path} as the App." >&2; return 1; }
    entries="$(jq -c --arg p "$path" --arg m "$mode" --arg s "$sha" '. + [{path: $p, mode: $m, type: "blob", sha: $s}]' <<< "$entries")"
  done < <(git -C "$wt" diff --cached --no-renames --name-status -z "$parent")
  tree="$(jq -c --arg b "$(git -C "$wt" rev-parse "${parent}^{tree}")" '{base_tree: $b, tree: .}' <<< "$entries" \
          | _gh_app_api POST git/trees | jq -r '.sha // empty')"
  [ -n "$tree" ] || { echo "ERROR: could not create the tree as the App." >&2; return 1; }
  commit="$(jq -nc --arg m "$msg" --arg t "$tree" --arg p "$parent" '{message: $m, tree: $t, parents: [$p]}' \
            | _gh_app_api POST git/commits | jq -r '.sha // empty')"
  [ -n "$commit" ] || { echo "ERROR: could not create the commit as the App." >&2; return 1; }
  remote="$(printf '' | _gh_app_api GET "git/ref/heads/${branch}" 2>/dev/null | jq -r '.object.sha // empty')"
  if [ -z "$remote" ]; then
    jq -nc --arg r "refs/heads/${branch}" --arg s "$commit" '{ref: $r, sha: $s}' | _gh_app_api POST git/refs >/dev/null \
      || _gh_app_ref_is "$branch" "$commit" || { echo "ERROR: could not create ${branch} as the App." >&2; return 1; }
  else
    expect="$(git -C "$wt" rev-parse -q --verify "refs/remotes/origin/${branch}" || true)"
    [ "$remote" = "$expect" ] || { echo "ERROR: origin/${branch} moved to ${remote:0:10} (expected ${expect:0:10}); refusing to overwrite it." >&2; return 1; }
    jq -nc --arg s "$commit" '{sha: $s, force: true}' | _gh_app_api PATCH "git/refs/heads/${branch}" >/dev/null \
      || _gh_app_ref_is "$branch" "$commit" || { echo "ERROR: could not move ${branch} as the App." >&2; return 1; }
  fi
  _retry git -C "$wt" fetch -q origin "+refs/heads/${branch}:refs/remotes/origin/${branch}" &&
    git -C "$wt" reset -q --soft "$commit" && git -C "$wt" branch -q --set-upstream-to "origin/${branch}" >/dev/null 2>&1
  printf '%s\n' "$commit"
}
