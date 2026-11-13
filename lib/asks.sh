#!/bin/bash
# asks.sh: actions the agent asks the host for. The agent ends a turn with 'host: <action> <args>' lines
# (_SESSION_FIN_JQ puts them in the turn end's .asks). The host runs each one only when a team admin
# started that turn, and tells the agent the result in a host note. The runner never holds a token.

_ASKS_MAX=20
_ASKS_PR_RE='^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/([0-9]+)$'

# asks_role <key> <admin 1|0> <name> [queued]   Who asked for the next turn. A turn from the queue takes
# the lowest role of the messages in it, so one message from a non-admin keeps the whole turn from asking.
# Call it before the message goes into the queue.
asks_role() {
  local key="$1" adm="${2:-0}" who="${3:-}" q="${SESSION_DIR}/${1}.queue"
  [ "$adm" = 1 ] || adm=0
  if [ -z "${4:-}" ]; then session_set "$key" turn_admin "$adm" turn_asker "$who"
  elif [ ! -s "$q" ]; then session_set "$key" q_admin "$adm" q_asker "$who"
  elif [ "$adm" = 0 ]; then session_set "$key" q_admin 0 q_asker "$who"; fi
}

# asks_from_queue <key>   The queue is about to go out as one turn: its role becomes the turn's.
asks_from_queue() {
  session_set "$1" turn_admin "$(session_get "$1" q_admin)" turn_asker "$(session_get "$1" q_asker)" q_admin "" q_asker ""
}

# asks_take <key> <events json>   A turn end's asks, with the role of the turn that wrote them, go to the
# asks job. The caller runs this once for each transcript line (the history cursor guards a re-read).
asks_take() {
  local key="$1" asks f="${SESSION_DIR}/${1}.asks.jsonl"
  # A 'target' line is lib/targets.sh's (targets_events).
  asks="$(jq -c '[.[] | select(.type == "turn_end" or .type == "question") | (.asks // [])[] | select(test("^target\\s") | not)] | .[0:10]' <<< "$2" 2>/dev/null || echo '[]')"
  [ "$asks" != '[]' ] || return 0
  jq -nc --argjson a "$asks" --arg adm "$(session_get "$key" turn_admin)" --arg who "$(session_get "$key" turn_asker)" \
    '{at: now, admin: ($adm == "1"), who: $who, asks: $a}' >> "$f"
  [ -n "${_ASKS_NO_JOB:-}" ] || nohup "${SCRIPT_DIR:-.}/fxa-sandbox-ctl" --backend gce session asks "$key" >> "${SESSION_DIR}/${key}.asks.log" 2>&1 < /dev/null &
  return 0
}

# session_asks <key>   The asks job: run each waiting ask, log who asked, and queue one host note with the
# results for the agent's next turn. One job at a time; a second start leaves the work to the first.
session_asks() {
  local key="$1" f="${SESSION_DIR}/${1}.asks.jsonl" lock="${SESSION_DIR}/${1}.asks.lock" row line out note="" adm who n
  mkdir "$lock" 2>/dev/null || return 0
  while [ -s "$f" ]; do
    mv "$f" "${f}.run"
    while IFS= read -r row; do
      adm="$(jq -r 'if .admin then 1 else 0 end' <<< "$row")"; who="$(jq -r '.who // ""' <<< "$row")"
      while IFS= read -r line; do
        n="$(session_get "$key" asks_n)"; n="${n:-0}"
        if [ "$n" -ge "$_ASKS_MAX" ]; then out="refused: this session reached its ${_ASKS_MAX} host actions. Start a new thread."
        else session_set "$key" asks_n "$((n + 1))"; out="$(_ask_one "$key" "$adm" "$who" "$line" 2>&1 < /dev/null | tail -3 | tr '\n' ' ' | sed 's/ *$//')"; fi
        jq -nc --arg k "$key" --arg w "$who" --arg a "$line" --arg o "$out" --argjson adm "$adm" \
          '{at: now, key: $k, asked_by: $w, admin: ($adm == 1), ask: $a, result: $o}' >> "${SESSION_DIR}/${key}.host-actions.jsonl"
        _session_history_add "$key" action "Host: ${line}: ${out} (asked by ${who:-someone})"
        note="${note}- \`${line}\`: ${out}
"
      done < <(jq -r '.asks[]' <<< "$row")
    done < "${f}.run"
    rm -f "${f}.run"
  done
  rmdir "$lock" 2>/dev/null || true
  [ -n "$note" ] || return 0
  # The note's turn keeps the role of the turn that asked, so a follow-up ask in it is judged the same way.
  asks_role "$key" "$(session_get "$key" turn_admin)" "$(session_get "$key" turn_asker)" queued
  printf '(Host: the results of your host lines.\n%s Tell the engineer the result in one line, then go on with the request.)\n\n' "$note" >> "${SESSION_DIR}/${key}.queue"
}

# asks_gate <admin 1|0> <who> <line>   The checks that need no session: the action list, the role, and
# the team's rules for the action's argument. Prints the refusal and fails; silent when the ask may run.
asks_gate() {
  local adm="$1" who="${2:-someone}" action rest why
  read -r action rest <<< "$3"
  case "$action" in
    merge|approve|auto-merge|automerge|enable-auto-merge)
      echo "refused: the host never merges, approves or turns on auto-merge. A person does that on GitHub."; return 1 ;;
    rerun-ci|request-review|ready|draft|comment|egress|add-repo) ;;
    *) echo "refused: ${action:-an empty line} is not a host action."; return 1 ;;
  esac
  [ "$adm" = 1 ] || { echo "refused: only a team admin of ${PIPE_PROFILE:-this team} can ask for this, and ${who} is not one. Ask a team admin to say it in the thread."; return 1; }
  case "$action" in
    # The team record's own check: a host that takes data out with no account is refused, for an admin too.
    egress) why="$(python3 "${SANDBOX_ROOT:-.}/lib/team_record.py" host-ok "$(tr 'A-Z' 'a-z' <<< "${rest%% *}")")" || { echo "refused: ${why}."; return 1; } ;;
    add-repo) _asks_repo_row "${rest%% *}" >/dev/null || { echo "refused: ${rest%% *} is not one of team ${PIPE_PROFILE:-?}'s repos. A team admin adds it to the team first."; return 1; } ;;
  esac
}

# _asks_repo_row <owner/repo or its URL>   The team record's row for a repo: "slug path role [base]".
# A team with no rows (FxA's conf) has its one work repo.
_asks_repo_row() {
  local want="${1%.git}" s p r b
  want="${want#https://github.com/}"
  [[ "$want" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
  while read -r s p r b; do
    [ "$(tr 'A-Z' 'a-z' <<< "$s")" = "$(tr 'A-Z' 'a-z' <<< "$want")" ] && { echo "$s $p $r${b:+ $b}"; return 0; }
  done < <(if [ -n "${PIPE_REPOS+x}" ]; then printf '%s\n' "${PIPE_REPOS[@]}"; else echo "${PIPE_REPO_SLUG:-mozilla/fxa} ${PIPE_WORKSPACE:-/home/agent/fxa} work"; fi)
  return 1
}

# _ask_one <key> <admin 1|0> <who> <line>   One ask. Prints the result in one line; fails when refused.
_ask_one() {
  local key="$1" action rest
  asks_gate "$2" "$3" "$4" || return 1
  read -r action rest <<< "$4"
  case "$action" in
    egress) _ask_egress "$key" "${rest%% *}" ;;
    add-repo) _ask_repo "$key" "${rest%% *}" ;;
    *) _ask_gh "$key" "$action" $rest ;;
  esac
}

# _asks_resolve <host>   The host's public IPv4 addresses, as this host resolves them.
_asks_resolve() {
  python3 -c 'import socket, sys, ipaddress
print(" ".join(sorted({a[4][0] for a in socket.getaddrinfo(sys.argv[1], 443, socket.AF_INET) if ipaddress.ip_address(a[4][0]).is_global})))' "$1" 2>/dev/null || true
}

# _ask_egress <key> <host>   Open one more host to this session's runner, for the agent user only.
# The host resolves the name: the agent may write the runner's /etc/hosts (sudo tee), so the runner's answer
# could point an allowed name at any address. A private address is never opened.
_ask_egress() {
  local key="$1" h have ips name
  h="$(tr 'A-Z' 'a-z' <<< "$2")"; have="$(session_get "$key" egress)"
  [ "${FXA_EGRESS_ALLOW_ALL:-0}" != 1 ] || { echo "done: this host runs with open egress, so ${h} is reachable."; return 0; }
  ! tr ' ' '\n' <<< "$have" | grep -qxF "$h" || { echo "done: ${h} is already open for this session."; return 0; }
  ips="$(_asks_resolve "$h")"
  [ -n "$ips" ] || { echo "failed: ${h} has no public IPv4 address."; return 1; }
  name="$(worktree_branch_for "$key")"
  # Before the agent's REJECT, so after the private-range DROPs; -C keeps a second ask from adding twice.
  vm_exec "$name" sudo env IPS="$ips" bash -c 'n=$(iptables -L OUTPUT --line-numbers -n | awk "/REJECT/ && /owner UID match/ {print \$1; exit}")
    [ -n "$n" ] || exit 1
    for ip in $IPS; do iptables -C OUTPUT -m owner --uid-owner agent -d "$ip" -j ACCEPT 2>/dev/null \
      || iptables -I OUTPUT "$n" -m owner --uid-owner agent -d "$ip" -j ACCEPT || exit 1; done' >/dev/null 2>&1 \
    || { echo "failed: the runner's firewall did not take ${h}."; return 1; }
  session_set "$key" egress "${have:+$have }${h}"
  # shellcheck disable=SC2046  # one argument per host
  _setup_agent_dns "$name" $(FXA_AGENT_RUNTIME="$(session_get "$key" runtime)" _egress_hosts) $(session_get "$key" egress) >/dev/null 2>&1 \
    || { echo "failed: the runner's DNS filter did not take ${h}."; return 1; }
  if vm_exec "$name" sudo -u agent timeout 8 bash -c "exec 3<>/dev/tcp/${h}/443" >/dev/null 2>&1; then
    echo "done: ${h} is open for this session's runner (${ips})."
  else echo "done: ${h} is open for this session's runner, but a test connection to port 443 did not answer."; fi
}

# _ask_pr <key> [url]   The PR an ask is for: the URL given, else the session's one PR. It must be the
# session's own, or in one of the team's work repos. Prints "slug number url".
_ask_pr() {
  local key="$1" url="${2:-}" own slug
  own="$(jq -r '[.pr_url, .review_pr, ((.trees // [])[] | .pr_url, .review_pr)] | map(select(. != null and . != "")) | unique[]' "$(_session_file "$key")" 2>/dev/null || true)"
  if [ -z "$url" ]; then
    [ "$(grep -c . <<< "$own" || true)" = 1 ] || { echo "refused: name the PR by its URL; this session has $(grep -c . <<< "$own" || true) PRs."; return 1; }
    url="$own"
  fi
  [[ "$url" =~ $_ASKS_PR_RE ]] || { echo "refused: ${url} is not a GitHub PR URL."; return 1; }
  slug="${BASH_REMATCH[1]}"
  if ! grep -qxF "$url" <<< "$own" && ! trees_allowed | awk '{print tolower($1)}' | grep -qxF "$(tr 'A-Z' 'a-z' <<< "$slug")"; then
    echo "refused: ${url} is not this session's PR, and ${slug} is not a work repo of team ${PIPE_PROFILE:-?}."; return 1
  fi
  printf '%s %s %s\n' "$slug" "${BASH_REMATCH[2]}" "$url"
}

# _ask_gh <key> <action> [PR URL] [args]   A GitHub action on a PR, with the App's token for its repo.
_ask_gh() {
  local key="$1" action="$2" url="" a args=() pr slug num
  shift 2
  for a in "$@"; do if [[ "$a" =~ ^https:// ]]; then url="$a"; else args+=("$a"); fi; done
  pr="$(_ask_pr "$key" "$url")" || { echo "$pr"; return 1; }
  read -r slug num url <<< "$pr"
  github_app_enabled 2>/dev/null || { echo "refused: the GitHub App is not set up on this host."; return 1; }
  local GH_TOKEN; GH_TOKEN="$(PIPE_REPO_SLUG="$slug" github_app_token 2>/dev/null)" || { echo "failed: no GitHub App token for ${slug}."; return 1; }
  export GH_TOKEN
  case "$action" in
    ready) gh pr ready "$url" >/dev/null 2>&1 && echo "done: ${url} is ready for review." || { echo "failed: GitHub refused to mark ${url} ready."; return 1; } ;;
    draft) gh pr ready "$url" --undo >/dev/null 2>&1 && echo "done: ${url} is a draft again." || { echo "failed: GitHub refused to make ${url} a draft."; return 1; } ;;
    request-review)
      local who=() r
      for r in ${args[@]+"${args[@]}"}; do r="${r#@}"; r="${r%,}"; [[ "$r" =~ ^[A-Za-z0-9-]{1,39}$ ]] && who+=(-f "reviewers[]=${r}"); done
      [ "${#who[@]}" -gt 0 ] || { echo "refused: name the reviewers by their GitHub logins."; return 1; }
      gh api -X POST "repos/${slug}/pulls/${num}/requested_reviewers" "${who[@]}" >/dev/null 2>&1 \
        && echo "done: asked $(printf '%s ' ${args[@]+"${args[@]}"} | sed 's/ *$//') to review ${url}." || { echo "failed: GitHub refused the review request on ${url}."; return 1; } ;;
    comment)
      local body; body="$(vm_exec_as_agent "$(worktree_branch_for "$key")" 'head -c 8000 /workspace/.fxa-host-comment.md 2>/dev/null; rm -f /workspace/.fxa-host-comment.md' 2>/dev/null \
        | perl -pe 's/(sk-ant-[a-z0-9]+-|fxl_|fxm_|xox[abpr]-|xapp-|ghs_|ghp_|gho_|github_pat_)[A-Za-z0-9_-]{8,}/$1<masked>/g' || true)"
      [ -n "$(tr -d '[:space:]' <<< "$body")" ] || { echo "refused: write the comment to /workspace/.fxa-host-comment.md first."; return 1; }
      # One post, no retry: a retried comment can post twice.
      printf '%s' "$body" | gh api -X POST "repos/${slug}/issues/${num}/comments" -F body=@- --jq .html_url 2>/dev/null | grep -E '^https://' \
        | sed 's/^/done: posted /' || { echo "failed: GitHub refused the comment on ${url}."; return 1; } ;;
    rerun-ci) _ask_rerun "$slug" "$url" ;;
  esac
}

# _ask_repo <key> <owner/repo>   Clone one of the team's repos into the running sandbox at its record path. The
# host clones it, with the App's read token for a private repo, and ships the tree: no token enters the runner.
# A work repo joins a team stack's trees and ships as they do; any other repo, or a work repo in a one-repo
# session (which ships only its own repo), is read-only.
_ask_repo() {
  local key="$1" slug path role base name dir tok="" sha leaf
  read -r slug path role base <<< "$(_asks_repo_row "$2")"
  base="${base:-${PIPE_BASE_BRANCH:-main}}"; leaf="${path##*/}"
  [[ "$path" =~ ^/home/agent/[a-z0-9-]+$ ]] || { echo "failed: the team record gives ${slug} no plain path."; return 1; }
  if [ "$(tr 'A-Z' 'a-z' <<< "$slug")" = "$(tr 'A-Z' 'a-z' <<< "${PIPE_REPO_SLUG:-}")" ] && ! trees_on "$key" || trees_idx "$key" "$slug" >/dev/null; then
    echo "done: ${slug} is already in this session."; return 0
  fi
  name="$(worktree_branch_for "$key")"
  vm_exec "$name" test -e "$path" >/dev/null 2>&1 && { echo "done: ${slug} is already on the runner at ${path}."; return 0; }
  if github_repo_private "$slug"; then
    tok="$(github_read_token "$slug")" || { echo "failed: no read token for ${slug}: is the GitHub App installed on it?"; return 1; }
  fi
  dir="$(mktemp -d)"
  # The token stays in the environment: no command line, no .git/config.
  TOK="$tok" GIT_TERMINAL_PROMPT=0 _with_timeout 600 git -c credential.helper= \
    -c 'credential.helper=!f() { [ -n "$TOK" ] && printf "username=x-access-token\npassword=%s\n" "$TOK"; }; f' \
    clone --quiet --depth 1 --branch "$base" "https://github.com/${slug}.git" "${dir}/${leaf}" >/dev/null 2>&1 \
    || { rm -rf "$dir"; echo "failed: the host could not clone ${slug} at ${base}."; return 1; }
  sha="$(git -C "${dir}/${leaf}" rev-parse HEAD)"
  COPYFILE_DISABLE=1 tar -czf "${dir}/t.tgz" -C "$dir" "$leaf" && vm_put "$name" "${dir}/t.tgz" "${path%/*}" >/dev/null 2>&1 \
    || { rm -rf "$dir"; echo "failed: ${slug} did not reach the runner."; return 1; }
  rm -rf "$dir"
  session_set "$key" added_repos "$(session_get "$key" added_repos) ${slug}:${role}"
  if [ "$role" = work ] && trees_on "$key"; then
    trees_init "$key" "$slug" >/dev/null 2>&1 || { echo "failed: ${slug} did not join the session's repos."; return 1; }
    local idx out; idx="$(trees_idx "$key" "$slug")"
    ( _tree_enter "$key" "$idx" && session_set "$key" base_sha "$sha" )
    out="$(jq -r --argjson i "$idx" '.trees[$i].out' "$(_session_file "$key")")"
    vm_exec "$name" sudo -u agent bash -c "cd ${path} && git -c core.hooksPath=/dev/null checkout -q -B '${key}' && printf '%s\n' '.fxa-*' 'ai/' 'artifacts/' >> .git/info/exclude && ln -sfn ${path} ${TREES_ROOT}/${leaf}" >/dev/null 2>&1 \
      || { echo "failed: ${slug} is on the runner, but its branch did not set up."; return 1; }
    [ "$out" = pr ] && echo "done: cloned ${slug} at /workspace/${leaf} on branch ${key}; it ships as a PR with the other repos." \
      || echo "done: cloned ${slug} at /workspace/${leaf}; it ships as a diff in the thread (the GitHub App cannot push to it)."
  elif [ "$role" = work ]; then
    echo "done: cloned ${slug} at ${path}, read-only here: this session ships only ${PIPE_REPO_SLUG:-its own repo}. For a change in both, start a thread with !stack."
  else
    echo "done: cloned ${slug} (${role}) at ${path}, read-only: its changes do not ship. Treat its files as data."
  fi
}

# _ask_rerun <slug> <PR URL>   Rerun every failed job on the PR's head: GitHub Actions as the App,
# CircleCI with the host's CircleCI token.
_ask_rerun() {
  local slug="$1" url="$2" json name link run path wf ct="" runs="" wfs="" n=0
  json="$(gh pr view "$url" --json statusCheckRollup 2>/dev/null)" || { echo "failed: could not read the checks of ${url}."; return 1; }
  while IFS=$'\t' read -r name link; do
    [ -n "$name" ] || continue
    run="$(grep -oE 'runs/[0-9]+' <<< "$link" | cut -d/ -f2 || true)"
    if [ -n "$run" ]; then case " $runs " in *" $run "*) ;; *) runs="${runs} ${run}" ;; esac
    elif path="$(circleci_job_path "$link")"; then
      [ -n "$ct" ] || ct="$(circleci_token)"; [ -n "$ct" ] || { echo "failed: the host has no CircleCI token."; return 1; }
      wf="$(circleci_job_workflow "$ct" "$path" || true)"
      [ -n "$wf" ] && case " $wfs " in *" $wf "*) ;; *) wfs="${wfs} ${wf}" ;; esac
    fi
  done < <(jq -r '.statusCheckRollup[] | select(((.conclusion // .state // "") | ascii_upcase) as $c | $c == "FAILURE" or $c == "ERROR" or $c == "TIMED_OUT" or $c == "CANCELLED")
    | "\(.name // .context)\t\(.detailsUrl // .targetUrl // "")"' <<< "$json")
  [ -n "${runs}${wfs}" ] || { echo "done: ${url} has no failed CI job to rerun."; return 0; }
  for run in $runs; do gh api -X POST "repos/${slug}/actions/runs/${run}/rerun-failed-jobs" >/dev/null 2>&1 && n=$((n + 1)); done
  for wf in $wfs; do circleci_rerun_failed "$ct" "$wf" && n=$((n + 1)); done
  [ "$n" -gt 0 ] || { echo "failed: GitHub and CircleCI refused every rerun on ${url}."; return 1; }
  echo "done: reran the failed jobs of ${n} CI run(s) on ${url}."
}
