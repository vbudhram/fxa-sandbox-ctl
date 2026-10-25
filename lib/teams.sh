#!/usr/bin/env bash
# Team records in the GCS state bucket (self-service teams spec, phase 0). One object for each team,
# teams/<name>.json, written only with --if-generation-match, so a stale write fails instead of
# replacing a newer one. FXA_TEAMS_DIR caches each record with its generation (<name>.gen) and its
# prompts (<name>/), and holds index.json, which the bot and the dashboard read.
# With no FXA_GCE_PROJECT (a laptop, a check), the cache is the store.

FXA_TEAMS_URI="${FXA_TEAMS_URI-${FXA_GCE_PROJECT:+gs://${FXA_GCE_PROJECT}-fxa-ai-fixme/teams}}"
_TEAMS_PY() { FXA_RESERVED_TEAMS="$(pipeline_folder_teams | tr '\n' ' ')" python3 -I "${SANDBOX_ROOT}/lib/team_record.py" "$@"; }

# _teams_actor   Who writes: FXA_TEAM_ACTOR, else the git email of this host.
_teams_actor() { printf '%s' "${FXA_TEAM_ACTOR:-$(git config user.email 2>/dev/null || true)}"; }

# _teams_remote_gen <name>   The live generation of the team's object, or nothing. Not objects list:
# the bucket keeps old versions, and list can name them too.
_teams_remote_gen() {
  gcloud storage objects describe "${FXA_TEAMS_URI}/$1.json" --format='value(generation)' 2>/dev/null
}

# _teams_audit <action> <name> <old gen> <new gen> <old file> <new file>   One team_audit row (lib/db.sh):
# the actor, and the top-level keys that changed. A failed write warns; it never undoes the change.
_teams_audit() {
  declare -F db_exec >/dev/null && command -v sqlite3 >/dev/null || return 0
  local changed; changed="$(jq -nr --slurpfile a "${5:-/dev/null}" --slurpfile b "${6:-/dev/null}" \
    '($a[0] // {}) as $o | ($b[0] // {}) as $n | [($o + $n | keys[]) | select(. != "updated" and $o[.] != $n[.])] | join(",")' 2>/dev/null)"
  db_exec "INSERT INTO team_audit (at, actor, team, action, old_gen, new_gen, changed) VALUES ($(date +%s), $(db_q "$(_teams_actor)"), $(db_q "$2"), $(db_q "$1"), $(db_q "$3"), $(db_q "$4"), $(db_q "$changed"));" >/dev/null 2>&1 \
    || echo "WARN: the audit row for team $2 was not written" >&2
}

# _teams_audit_note <action> <name> <what>   An audit row that names what changed, with no record diff
# (a secret's new version: its name only, never its value).
_teams_audit_note() {
  declare -F db_exec >/dev/null && command -v sqlite3 >/dev/null || return 0
  db_exec "INSERT INTO team_audit (at, actor, team, action, old_gen, new_gen, changed) VALUES ($(date +%s), $(db_q "$(_teams_actor)"), $(db_q "$2"), $(db_q "$1"), '', '', $(db_q "$3"));" >/dev/null 2>&1 \
    || echo "WARN: the audit row for team $2 was not written" >&2
}

# teams_secret_names <name>   The Secret Manager names the team's record uses (jira, runtime), one a line.
teams_secret_names() { jq -r '[.secrets.jira // empty] + [.secrets.runtime[]?.secret] | .[]' "${FXA_TEAMS_DIR}/$1.json" 2>/dev/null; }

# teams_secret_status <name>   {"<secret>": "present" | "missing"} for the team's secrets, as the manager reads them.
teams_secret_status() {
  local s out="{}"
  for s in $(teams_secret_names "$1"); do
    if gcloud secrets versions access latest --secret "$s" ${FXA_GCE_PROJECT:+--project "$FXA_GCE_PROJECT"} >/dev/null 2>&1; then
      out="$(jq -c --arg s "$s" '. + {($s): "present"}' <<< "$out")"
    else out="$(jq -c --arg s "$s" '. + {($s): "missing"}' <<< "$out")"; fi
  done
  printf '%s\n' "$out"
}

# teams_secret_set <name> <secret>   WRITE: store stdin as the new version of a secret the team's record
# names. It writes as FXA_TEAM_SECRETS_SA, an account that IAM lets touch fxa-team-* secrets only, so
# a misused caller reaches no other secret. The value is never on a command line, in a log or in the
# audit row, and the team's cached Jira credential is dropped so the next load reads the new one.
teams_secret_set() {
  local team="$1" sec="$2" v
  [[ "$team" =~ ^[a-z][a-z0-9-]{1,30}$ ]] && [ -f "${FXA_TEAMS_DIR}/${team}.json" ] || { echo "ERROR: no team record ${team}" >&2; return 1; }
  teams_secret_names "$team" | grep -qxF "$sec" && [[ "$sec" =~ ^fxa-team-${team}--[a-z0-9]+(-[a-z0-9]+)*$ ]] \
    || { echo "ERROR: team ${team}'s record does not name the secret ${sec}" >&2; return 1; }
  [ -n "${FXA_TEAM_SECRETS_SA:-}" ] || { echo "ERROR: no writer account (FXA_TEAM_SECRETS_SA) on this host; in a terminal: vm.sh secret ${sec}" >&2; return 1; }
  # A private temp file, not a variable: a value's trailing newline (a key, a PEM) survives.
  local f n rc=0; f="$(mktemp "${TMPDIR:-/tmp}/fxa-sec.XXXXXX")" || return 1
  cat > "$f"; n="$(wc -c < "$f" | tr -d ' ')"
  { [ "$n" -gt 0 ] && [ "$n" -le 8192 ]; } || { rm -f "$f"; echo "ERROR: the value is empty or over 8 KB" >&2; return 1; }
  if [ "$sec" = "$(jq -r '.secrets.jira // empty' "${FXA_TEAMS_DIR}/${team}.json")" ]; then
    [[ "$(cat "$f")" =~ ^[^:@[:space:]]+@[^:[:space:]]+:[^[:space:]]+$ ]] || { rm -f "$f"; echo "ERROR: a Jira credential is email:token" >&2; return 1; }
  fi
  local -a as=(--impersonate-service-account "$FXA_TEAM_SECRETS_SA" ${FXA_GCE_PROJECT:+--project "$FXA_GCE_PROJECT"})
  if gcloud secrets describe "$sec" "${as[@]}" >/dev/null 2>&1; then
    gcloud secrets versions add "$sec" --data-file="$f" "${as[@]}" >/dev/null 2>&1 || rc=1
  else
    gcloud secrets create "$sec" --replication-policy=automatic --data-file="$f" "${as[@]}" >/dev/null 2>&1 || rc=1
  fi
  rm -f "$f"
  [ "$rc" = 0 ] || { echo "ERROR: could not store ${sec} (may the writer account write fxa-team-* secrets?)" >&2; return 1; }
  rm -f "${FXA_TEAMS_SECRET_DIR:-${HOME}/.config/fxa/teams}/${team}/jira.basic"
  _teams_audit_note secret "$team" "$sec"
  echo "stored a new version of ${sec}"
}

# teams_audit <name>   The team's audit rows, newest first, as JSON.
teams_audit() {
  [[ "$1" =~ ^[a-z][a-z0-9-]{1,30}$ ]] || { echo "ERROR: bad team name" >&2; return 1; }
  db_json "SELECT at, actor, action, old_gen, new_gen, changed FROM team_audit WHERE team = $(db_q "$1") ORDER BY id DESC LIMIT 200;"
}

# teams_index   Rebuild index.json from the cached records, in one rename.
teams_index() {
  mkdir -p "$FXA_TEAMS_DIR"
  # No reserved names: a host whose tree still has a team's folder writes the same index as one without.
  FXA_RESERVED_TEAMS= python3 -I "${SANDBOX_ROOT}/lib/team_record.py" index "$FXA_TEAMS_DIR" > "${FXA_TEAMS_DIR}/index.json.$$" && mv -f "${FXA_TEAMS_DIR}/index.json.$$" "${FXA_TEAMS_DIR}/index.json"
}

# _teams_cache <name> <file> <gen>   Put a record in the cache with its generation and prompts.
_teams_cache() {
  mkdir -p "$FXA_TEAMS_DIR"
  cp "$2" "${FXA_TEAMS_DIR}/$1.json.$$" && mv -f "${FXA_TEAMS_DIR}/$1.json.$$" "${FXA_TEAMS_DIR}/$1.json" || return 1
  printf '%s\n' "$3" > "${FXA_TEAMS_DIR}/$1.gen"
  _TEAMS_PY prompts "${FXA_TEAMS_DIR}/$1.json" "${FXA_TEAMS_DIR}/$1"
}

# _teams_pull <name>   Fetch one record and its generation from the bucket into the cache.
_teams_pull() {
  local gen tmp
  gen="$(_teams_remote_gen "$1")"; [[ "$gen" =~ ^[0-9]+$ ]] || return 1
  tmp="$(mktemp "${TMPDIR:-/tmp}/fxa-team.XXXXXX")"
  # The generation in the URL: the content and the generation always match.
  gcloud storage cat "${FXA_TEAMS_URI}/$1.json#${gen}" > "$tmp" 2>/dev/null && _teams_cache "$1" "$tmp" "$gen"; local rc=$?
  rm -f "$tmp"; return $rc
}

# _teams_live <file>   Facts outside the record, checked live: the GitHub App on each work repo, and
# the Jira project and what the pipeline's login may do there. WARN lines (stdout) do not refuse a
# write; ERROR lines (stderr) do: an active queue whose login cannot edit or transition its tickets
# would lose track of them and launch one again on every pass. FXA_TEAMS_LIVE=0 skips the checks.
_teams_live() {
  [ "${FXA_TEAMS_LIVE:-1}" = 1 ] || return 0
  local f="$1" s code proj st queue have p miss="" rc=0
  for s in $(jq -r '.repos[]? | select(.role == "work") | .slug' "$f"); do
    code="$(_gh_jwt_conf 2>/dev/null | curl -s -o /dev/null -w '%{http_code}' --max-time 20 -K - \
      -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/${s}/installation" 2>/dev/null)" || code=000
    case "$code" in
      200) ;;
      404) echo "WARN: the agent's GitHub App is not installed on ${s}, so its changes ship as a diff" ;;
      *) echo "WARN: could not check the GitHub App on ${s} (HTTP ${code})" ;;
    esac
  done
  # A private repo, of any role: only the App's read token clones it, and its code must not reach everyone.
  for s in $(jq -r '.repos[]?.slug' "$f"); do
    github_repo_private "$s" || continue
    code="$(_gh_jwt_conf 2>/dev/null | curl -s -o /dev/null -w '%{http_code}' --max-time 20 -K - \
      -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/${s}/installation" 2>/dev/null)" || code=000
    [ "$code" = 200 ] || { echo "ERROR: ${s} is private (or GitHub did not answer), and the agent's GitHub App is not installed on it (HTTP ${code}), so a runner cannot clone it" >&2; rc=1; }
    [ "$(jq -r '.access.open // false' "$f")" != true ] || { echo "ERROR: ${s} is private, so the team cannot be open to everyone: set access.users instead of access.open" >&2; rc=1; }
  done
  # A team that takes secret tickets: GitHub must confirm each work repo private, now and at every read.
  if [ "$(jq -r '.jira.secret // false' "$f")" = true ]; then
    local why n; n="$(jq -r '.name' "$f")"
    for s in $(jq -r '.repos[]? | select(.role == "work") | .slug' "$f"); do
      why="$(github_repo_confirmed_private "$s" 2>&1)" && continue
      case "$why" in
        *" is public") echo "ERROR: ${s} is public, so team ${n} cannot take secret tickets: remove jira.secret or use a private work repo" >&2 ;;
        *) echo "ERROR: ${why}. Validate again when GitHub answers." >&2 ;;
      esac
      rc=1
    done
    echo "WARN: a ticket with only a security level (no secret label) runs only when the pipeline's Jira login can see it"
  fi
  [ "$rc" -eq 0 ] || return 1
  proj="$(jq -r '.jira.project // empty' "$f")"; [ -n "$proj" ] || return 0
  st="$(jq -r '.status // "draft"' "$f")"; queue="$(jq -r '.jira.queue // false' "$f")"
  # The team's own Jira credential when it names one (secrets.jira), else the shared login.
  local sec PIPE_JIRA_BASIC="${PIPE_JIRA_BASIC:-}"; sec="$(jq -r '.secrets.jira // empty' "$f")"
  if [ -n "$sec" ]; then
    PIPE_JIRA_BASIC="$(gcloud secrets versions access latest --secret "$sec" ${FXA_GCE_PROJECT:+--project "$FXA_GCE_PROJECT"} 2>/dev/null)" || PIPE_JIRA_BASIC=""
    if [ -z "$PIPE_JIRA_BASIC" ]; then
      [ "$st" = active ] && [ "$queue" = true ] && { echo "ERROR: cannot read the team's Jira credential ${sec}: store it with vm.sh secret ${sec} (email:token)" >&2; return 1; }
      echo "WARN: cannot read the team's Jira credential ${sec} yet: store it with vm.sh secret ${sec} (email:token)"; return 0
    fi
  fi
  [ -n "${PIPE_JIRA_BASIC:-}" ] || { echo "WARN: no Jira login on this host (PIPE_JIRA_BASIC), so Jira project ${proj} was not checked"; return 0; }
  local api; api="$(_jira_api)" || api=""
  code="$(printf 'user = "%s"\n' "$PIPE_JIRA_BASIC" | curl -s -K - -o /dev/null -w '%{http_code}' --max-time 20 "${api}/rest/api/3/project/${proj}" 2>/dev/null)" || code=000
  case "$code" in
    200) ;;
    404) echo "ERROR: there is no Jira project ${proj}, or the pipeline's login cannot see it" >&2; return 1 ;;
    *) echo "WARN: could not check Jira project ${proj} (HTTP ${code})"; return 0 ;;
  esac
  have="$(printf 'user = "%s"\n' "$PIPE_JIRA_BASIC" | curl -s -K - --max-time 20 \
    "${api}/rest/api/3/mypermissions?projectKey=${proj}&permissions=BROWSE_PROJECTS,EDIT_ISSUES,TRANSITION_ISSUES" 2>/dev/null \
    | jq -r '[.permissions // {} | to_entries[] | select(.value.havePermission) | .key] | join(" ")' 2>/dev/null)" || have=""
  for p in BROWSE_PROJECTS EDIT_ISSUES TRANSITION_ISSUES; do grep -qw "$p" <<< "$have" || miss="${miss} ${p}"; done
  [ -n "$miss" ] || return 0
  if [ "$st" = active ] && [ "$queue" = true ]; then
    echo "ERROR: the pipeline's Jira login lacks${miss} on ${proj}, so an active queue there would lose track of its tickets; turn the queue off, or get the login those rights" >&2; rc=1
  else
    echo "WARN: the pipeline's Jira login lacks${miss} on ${proj}; turning its queue on is refused until it has them"
  fi
  return $rc
}

# teams_validate <file> [<name>]   The record's own rules, then its clashes with the other teams,
# then the live checks.
teams_validate() {
  local f="$1" name="${2:-}" builtin="" p
  [ -n "$name" ] || name="$(jq -r '.name // empty' "$f" 2>/dev/null)"
  _TEAMS_PY validate "$f" "$name" || return 1
  # The built-in teams' Jira projects, so a record cannot take FxA's queue.
  for p in "${SANDBOX_ROOT}"/profiles/*/profile.conf; do
    p="$( ( pipeline_load "$(basename "$(dirname "$p")")" >/dev/null 2>&1 && printf '%s:%s' "${PIPE_JIRA_PROJECT:-$([ "$PIPE_PROFILE" = fxa ] && echo FXA)}" "$PIPE_PROFILE" ) )"
    [[ "$p" =~ ^[A-Z][A-Z0-9]*: ]] && builtin="${builtin} ${p}"
  done
  FXA_BUILTIN_JIRA="$builtin" _TEAMS_PY unique "$f" "$FXA_TEAMS_DIR" || return 1
  _teams_live "$f"
}

# _teams_write <name> <file> <gen>   Write the record if the store still holds <gen> (0: no record yet).
_teams_write() {
  local name="$1" f="$2" gen="$3" out cur
  if [ -z "$FXA_TEAMS_URI" ]; then
    cur="$(cat "${FXA_TEAMS_DIR}/${name}.gen" 2>/dev/null || echo 0)"; [ -f "${FXA_TEAMS_DIR}/${name}.json" ] || cur=0
    [ "$cur" = "$gen" ] || { echo "ERROR: team ${name} changed since generation ${gen} (now ${cur}); run profile sync and edit again" >&2; return 2; }
    _teams_cache "$name" "$f" "$((cur + 1))" && teams_index; return
  fi
  if ! out="$(gcloud storage cp -q "$f" "${FXA_TEAMS_URI}/${name}.json" --if-generation-match="$gen" 2>&1)"; then
    grep -qiE 'precondition|412' <<< "$out" \
      && { echo "ERROR: team ${name} changed since generation ${gen}; run profile sync and edit again" >&2; return 2; }
    echo "ERROR: could not write team ${name}: $(tail -1 <<< "$out")" >&2; return 1
  fi
  # The store has the change: a failed read-back is a warning, so the caller still writes the audit row.
  # The cached generation is now stale: drop it, so the audit says unknown and the next edit asks for a sync.
  _teams_pull "$name" && teams_index || { rm -f "${FXA_TEAMS_DIR}/${name}.gen"; echo "WARN: wrote team ${name}, but could not read it back; run profile sync before the next edit" >&2; }
  return 0
}

# teams_create <file>   A new team. Refused when the name is a built-in team or already has a record.
teams_create() {
  local f="$1" name tmp rc
  name="$(jq -r '.name // empty' "$f" 2>/dev/null)"
  [[ "$name" =~ ^[a-z][a-z0-9-]{1,30}$ ]] || { echo "ERROR: the record needs a name" >&2; return 1; }
  [ "$(jq -r '.status // "draft"' "$f")" != active ] || [ "${FXA_TEAMS_SKIP_TEST:-}" = 1 ] \
    || { echo "ERROR: a new team starts as draft: create it, run profile test ${name}, then enable it" >&2; return 1; }
  teams_validate "$f" "$name" || return 1
  tmp="$(mktemp "${TMPDIR:-/tmp}/fxa-team.XXXXXX")"
  local at; at="$(date +%s)"
  _TEAMS_PY stamp "$f" "$(_teams_actor)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$tmp" || { rm -f "$tmp"; return 1; }
  # Test files from a name deleted before teams_delete removed them must not count for the new team.
  rm -f "${FXA_TEAMS_DIR:?}/${name}.tested" "${FXA_TEAMS_DIR:?}/${name}.test.log" "${FXA_TEAMS_DIR:?}/${name}.test.pid"
  _teams_write "$name" "$tmp" 0; rc=$?
  [ "$rc" = 0 ] && _teams_audit create "$name" 0 "$(cat "${FXA_TEAMS_DIR}/${name}.gen" 2>/dev/null || echo unknown)" "" "$tmp"
  rm -f "$tmp"
  [ "$rc" = 2 ] && echo "ERROR: team ${name} already exists; use profile set" >&2
  [ "$rc" = 0 ] && echo "created team ${name} (generation $(cat "${FXA_TEAMS_DIR}/${name}.gen" 2>/dev/null || echo unknown))"
  # Only after the write: a refused create must not touch the routines of the team that holds the name.
  [ "$rc" = 0 ] && { routines_clear_name "$name" "$((at + 1))" || { echo "ERROR: team ${name} is created, but old routines under its name remain; delete them" >&2; rc=1; }; }
  return $rc
}

# teams_set <name> <file> [<gen>]   Replace a team's record. <gen> defaults to the cached one, so an
# edit of a stale copy fails instead of undoing someone else's change.
teams_set() {
  local name="$1" f="$2" gen="${3:-}" tmp rc
  [ "$(jq -r '.name // empty' "$f" 2>/dev/null)" = "$name" ] || { echo "ERROR: the record's name is not ${name}; a team cannot be renamed" >&2; return 1; }
  [ -f "${FXA_TEAMS_DIR}/${name}.json" ] || { echo "ERROR: no team ${name} here; run profile sync, or profile create" >&2; return 1; }
  gen="${gen:-$(cat "${FXA_TEAMS_DIR}/${name}.gen" 2>/dev/null)}"
  [[ "$gen" =~ ^[0-9]+$ ]] || { echo "ERROR: no generation for team ${name}; run profile sync" >&2; return 1; }
  # Active only through profile enable (a passed test), and an active team keeps its test only for
  # changes a runner never reads.
  if [ "$(jq -r '.status // "draft"' "$f")" = active ] && [ "${FXA_TEAMS_SKIP_TEST:-}" != 1 ]; then
    local k
    [ "$(jq -r '.status // "draft"' "${FXA_TEAMS_DIR}/${name}.json")" = active ] || [ -n "${_TEAMS_ENABLING:-}" ] \
      || { echo "ERROR: turn team ${name} active with profile enable, after profile test ${name} passes" >&2; return 1; }
    k="$(_teams_runner_keys "${FXA_TEAMS_DIR}/${name}.json" "$f")"
    [ -z "$k" ] || { echo "ERROR: team ${name} is active, and a change to ${k} needs a new test: save it with status draft, run profile test ${name}, then enable it" >&2; return 1; }
  fi
  teams_validate "$f" "$name" || return 1
  tmp="$(mktemp "${TMPDIR:-/tmp}/fxa-team.XXXXXX")"
  _TEAMS_PY stamp "$f" "$(_teams_actor)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${FXA_TEAMS_DIR}/${name}.json" > "$tmp" || { rm -f "$tmp"; return 1; }
  local old; old="$(mktemp "${TMPDIR:-/tmp}/fxa-team.XXXXXX")"; cp "${FXA_TEAMS_DIR}/${name}.json" "$old"
  _teams_write "$name" "$tmp" "$gen"; rc=$?
  [ "$rc" = 0 ] && _teams_audit set "$name" "$gen" "$(cat "${FXA_TEAMS_DIR}/${name}.gen" 2>/dev/null || echo unknown)" "$old" "$tmp"
  rm -f "$tmp" "$old"
  [ "$rc" = 0 ] && echo "updated team ${name} (generation $(cat "${FXA_TEAMS_DIR}/${name}.gen" 2>/dev/null || echo unknown))"
  return $rc
}

# _teams_runner_keys <old.json> <new.json>   The top-level keys that changed, other than the ones a
# runner never reads (text, people, caps, Jira, PR rules, stamps).
_teams_runner_keys() {
  jq -nr --slurpfile a "$1" --slurpfile b "$2" '$a[0] as $o | $b[0] as $n
    | [(($o | keys) + ($n | keys)) | unique[]
       | select(IN("schema", "name", "label", "status", "admins", "access", "jira", "pr", "caps", "prompts", "created", "updated") | not)
       | select($o[.] != $n[.])] | join(" ")'
}

# _teams_probe_script   The checks a test runs on the runner as agent, from the loaded team; one
# "ok <what>" or "FAIL <what>" line each. Every value went through the loader's checks.
_teams_probe_script() {
  local row s p r b h k
  echo 'r() { if eval "$2" >/dev/null 2>&1; then echo "ok   $1"; else echo "FAIL $1"; fi; }'
  echo 'wait_for() { local i; for i in $(seq "$1"); do eval "$2" >/dev/null 2>&1 && return 0; sleep 5; done; return 1; }'
  for row in ${PIPE_REPOS[@]+"${PIPE_REPOS[@]}"}; do
    read -r s p r b <<< "$row"; echo "r 'repo ${s} is checked out at ${p}' 'git -C ${p} rev-parse --verify HEAD'"
  done
  if [ -n "${PIPE_BOOT_SCRIPT:-}" ] || [ -f "${SANDBOX_ROOT}/profiles/${PIPE_PROFILE}/boot.sh" ]; then
    echo "wait_for 120 '[ -f /run/fxa-profile/ready ] || [ -f /run/fxa-profile/failed ]'; r 'the boot script finished ready' '[ -f /run/fxa-profile/ready ]'"
  fi
  [ -n "${PIPE_STACK_DIR:-}" ] && echo "wait_for 84 'curl -sf --max-time 5 http://localhost:9000/__heartbeat__'; r 'the FxA stack answers on :9000' 'curl -sf --max-time 5 http://localhost:9000/__heartbeat__'"
  for h in ${PIPE_EGRESS_EXTRA:-}; do echo "r 'egress to ${h} is open' 'curl -s -o /dev/null --max-time 10 https://${h}'"; done
  echo "r 'a host the team did not approve is blocked' '! curl -s -o /dev/null --max-time 8 https://example.com'"
  for k in ${PIPE_TEAM_SKILLS:-}; do echo "r 'skill ${k} is installed' '[ -d ~/.claude/skills/${k} ]'"; done
}

# teams_test <name>   Boot one runner as the team, check what it needs, and stop it. A pass records
# the generation it tested (<name>.tested): a record turns active only at a tested generation.
teams_test() {
  local name="$1" ctl="${SCRIPT_DIR:-.}/fxa-sandbox-ctl" key f gen out rc=0
  [[ "$name" =~ ^[a-z][a-z0-9-]{1,30}$ ]] && [ -f "${FXA_TEAMS_DIR}/${name}.json" ] || { echo "ERROR: no team record ${name}; run profile sync" >&2; return 1; }
  # A pass records the generation it tested, so a test with none is refused, not run.
  gen="$(cat "${FXA_TEAMS_DIR}/${name}.gen" 2>/dev/null || true)"
  [[ "$gen" =~ ^[0-9]+$ ]] || { echo "ERROR: no generation for team ${name}; run profile sync" >&2; return 1; }
  key="agent-tst$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 5 || true)"
  f="$(mktemp "${TMPDIR:-/tmp}/fxa-team.XXXXXX")"
  echo 'This is a test boot of the team. Reply with the one word: ready. Change nothing and run nothing.' > "$f"
  echo "== ${name} at generation ${gen}: booting ${key} (a few minutes)"
  # A team with a stack gets it started, so the probe's stack check has something to find.
  local stack=""; stack="$( (pipeline_load "$name" >/dev/null 2>&1 && [ -n "${PIPE_STACK_DIR:-}" ] && echo 1) || true)"
  if ! FXA_SESSION_STACK="$stack" "$ctl" --backend gce --pipeline "$name" task --source slack --id "$key" --owner U-DRYRUN --prompt-file "$f" >/dev/null 2>&1; then
    rm -f "$f"; echo "FAIL the runner did not start; see ${SESSION_DIR}/${key}.log"; echo "failed: team ${name} stays as it is"; return 1
  fi
  rm -f "$f"
  # The dashboard's Stop sends TERM: stop the runner too, so a stopped test leaves nothing up.
  trap '"$ctl" --backend gce stop "$key" >/dev/null 2>&1; echo "== stopped ${key}: the test was stopped"; echo "failed: team ${name} stays as it is (the test was stopped)"; exit 143' TERM
  if FXA_TRY_TURN_SECONDS="${FXA_TEAMS_TEST_SECONDS:-1200}" _session_try_wait "$ctl" "$key" && [ "${_TRY_LAST:-}" != error ]; then
    echo "ok   the runner booted and the agent answered"
    # A failed probe ssh fails the test here; under set -e it would end the command and leave the runner up.
    out="$( ( pipeline_load "$name" >/dev/null 2>&1 && _session_sh "$(worktree_branch_for "$key")" "$(_teams_probe_script)" ) 2>&1)" || true
    printf '%s\n' "$out" | grep -E '^(ok|FAIL) ' || true
    grep -qE '^ok ' <<< "$out" && ! grep -q '^FAIL ' <<< "$out" || rc=1
  else
    echo "FAIL the runner did not finish its first turn${_TRY_LAST:+ (it ended in ${_TRY_LAST})}; see ${SESSION_DIR}/${key}.log"; rc=1
  fi
  trap - TERM
  "$ctl" --backend gce stop "$key" >/dev/null 2>&1 || echo "WARN: the stop of ${key} failed; fxa-sandbox-ctl stop ${key}" >&2
  echo "== stopped ${key}"
  if [ "$rc" = 0 ]; then printf '%s\n' "$gen" > "${FXA_TEAMS_DIR}/${name}.tested"; echo "passed: team ${name} may be activated at generation ${gen}"
  else echo "failed: team ${name} stays as it is"; fi
  return $rc
}

# teams_status <name> <draft|active|disabled>
teams_status() {
  local name="$1" st="$2" tmp rc
  case "$st" in draft|active|disabled) ;; *) echo "ERROR: status is draft, active or disabled" >&2; return 1 ;; esac
  [ -f "${FXA_TEAMS_DIR}/${name}.json" ] || { echo "ERROR: no team ${name} here; run profile sync" >&2; return 1; }
  # Turning active needs a passed test of this very generation: an edit since then needs a new one.
  if [ "$st" = active ] && [ "$(jq -r '.status // "draft"' "${FXA_TEAMS_DIR}/${name}.json")" != active ] \
     && [ "$(cat "${FXA_TEAMS_DIR}/${name}.tested" 2>/dev/null)" != "$(cat "${FXA_TEAMS_DIR}/${name}.gen" 2>/dev/null)" ] \
     && [ "${FXA_TEAMS_SKIP_TEST:-}" != 1 ]; then
    echo "ERROR: team ${name} has no passed test at its generation: run profile test ${name} (it boots one runner), then enable it" >&2
    return 1
  fi
  tmp="$(mktemp "${TMPDIR:-/tmp}/fxa-team.XXXXXX")"
  # Turning a team off skips the live checks: a broken GitHub App or Jira project must not keep it on.
  local live="${FXA_TEAMS_LIVE:-1}"; [ "$st" = active ] || live=0
  local carry=""
  [ "$st" = active ] && [ -n "$(cat "${FXA_TEAMS_DIR}/${name}.gen" 2>/dev/null)" ] \
    && [ "$(cat "${FXA_TEAMS_DIR}/${name}.tested" 2>/dev/null)" = "$(cat "${FXA_TEAMS_DIR}/${name}.gen" 2>/dev/null)" ] && carry=1
  jq --arg s "$st" '.status = $s' "${FXA_TEAMS_DIR}/${name}.json" > "$tmp" && _TEAMS_ENABLING=1 FXA_TEAMS_LIVE="$live" teams_set "$name" "$tmp"; rc=$?
  # Activate writes a new generation that differs only in status, so the pass still holds for it.
  if [ "$rc" = 0 ] && [ -n "$carry" ] && [ -s "${FXA_TEAMS_DIR}/${name}.gen" ]; then cp "${FXA_TEAMS_DIR}/${name}.gen" "${FXA_TEAMS_DIR}/${name}.tested"; fi
  rm -f "$tmp"; return $rc
}

# teams_delete <name>   Remove a team. Refused while one of its sessions can still resume.
teams_delete() {
  local name="$1" gen f n=0
  # A record team may keep profiles/<name>/ for its boot.sh and skills; only a profile.conf makes a folder team.
  [[ "$name" =~ ^[a-z][a-z0-9-]{1,30}$ ]] && [ ! -f "${SANDBOX_ROOT}/profiles/${name}/profile.conf" ] || { echo "ERROR: ${name} is not a team record" >&2; return 1; }
  for f in "$SESSION_DIR"/agent-*.json; do
    [ -f "$f" ] && [ "$(jq -r '.profile // empty' "$f" 2>/dev/null)" = "$name" ] \
      && case "$(jq -r '.state // empty' "$f")" in stopped|failed) ;; *) n=$((n + 1)) ;; esac
  done
  [ "$n" = 0 ] || { echo "ERROR: team ${name} has ${n} session(s) that can resume; stop them first" >&2; return 1; }
  gen="$(cat "${FXA_TEAMS_DIR}/${name}.gen" 2>/dev/null || true)"
  [ -z "$FXA_TEAMS_URI" ] || [[ "$gen" =~ ^[0-9]+$ ]] || { echo "ERROR: no generation for team ${name}; run profile sync" >&2; return 1; }
  # Every refusal is above. The marker stops a routine save from racing the drop; then its routines go,
  # so a later team of this name never inherits them. A store error stops the delete with nothing gone.
  touch "${FXA_TEAMS_DIR}/${name}.deleting"
  routines_drop_team "$name" || { rm -f "${FXA_TEAMS_DIR}/${name}.deleting"; echo "ERROR: team ${name} is not deleted" >&2; return 1; }
  if [ -n "$FXA_TEAMS_URI" ]; then
    gcloud storage rm -q "${FXA_TEAMS_URI}/${name}.json" --if-generation-match="$gen" >/dev/null 2>&1 \
      || { rm -f "${FXA_TEAMS_DIR}/${name}.deleting"; echo "ERROR: could not delete team ${name} (changed since generation ${gen}?); run profile sync. Its routines are already removed." >&2; return 1; }
  fi
  _teams_audit delete "$name" "$gen" "" "${FXA_TEAMS_DIR}/${name}.json" ""
  # The test files go too, so a team re-created under this name never shows the old team's test.
  rm -rf "${FXA_TEAMS_DIR:?}/${name}.json" "${FXA_TEAMS_DIR:?}/${name}.gen" "${FXA_TEAMS_DIR:?}/${name}" "${FXA_TEAMS_DIR:?}/${name}.deleting" \
    "${FXA_TEAMS_DIR:?}/${name}.tested" "${FXA_TEAMS_DIR:?}/${name}.test.log" "${FXA_TEAMS_DIR:?}/${name}.test.pid"
  teams_index && echo "deleted team ${name}"
}

# teams_sync   Make the cache match the bucket: every record at its current generation, none extra.
teams_sync() {
  [ -n "$FXA_TEAMS_URI" ] || { teams_index; echo "no team store (FXA_GCE_PROJECT is unset): the cache is the store"; return 0; }
  local names n f rc=0
  # ls names live objects only (objects list also names a deleted team's old versions).
  # An empty store is not an error: GCS says "matched no objects".
  if ! names="$(gcloud storage ls "${FXA_TEAMS_URI}/*.json" 2>&1)"; then
    grep -qi 'matched no objects' <<< "$names" || { echo "ERROR: could not list ${FXA_TEAMS_URI}: $(tail -1 <<< "$names")" >&2; return 1; }
    names=""
  fi
  names="$(printf '%s\n' "$names" | sed -n 's#^.*/##; s#\.json$##p' | grep -E '^[a-z][a-z0-9-]{1,30}$' | sort -u || true)"
  local seen at
  for n in $names; do
    seen=0; [ -f "${FXA_TEAMS_DIR}/${n}.json" ] && seen=1
    _teams_pull "$n" || { echo "WARN: could not fetch team ${n}" >&2; continue; }
    [ "$seen" = 1 ] && continue
    # A record new to this host: rows from before its created time are an earlier team's.
    at="$(jq -r '.created.at // empty' "${FXA_TEAMS_DIR}/${n}.json")"; [ -z "$at" ] || at="$(_epoch_of "$at" 2>/dev/null || true)"
    routines_clear_name "$n" "$at" || rc=1
  done
  for f in "$FXA_TEAMS_DIR"/*.json; do
    n="$(basename "$f" .json)"; [ -f "$f" ] && [ "$n" != index ] || continue
    grep -qx "$n" <<< "$names" && continue
    # A team deleted on another host: its routines go too, as teams_delete does. A store error keeps the
    # cached record, so the next sync tries again.
    routines_drop_team "$n" || { rc=1; continue; }
    rm -rf "${FXA_TEAMS_DIR:?}/${n}.json" "${FXA_TEAMS_DIR:?}/${n}.gen" "${FXA_TEAMS_DIR:?}/${n}"; echo "removed team ${n} (no longer in the store)"
  done
  teams_index && echo "teams: $(printf '%s\n' "$names" | grep -c . || true) in the store" && return "$rc"
}
