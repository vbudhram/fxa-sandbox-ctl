#!/usr/bin/env bash
# Team records in the GCS state bucket (self-service teams spec, phase 0). One object for each team,
# teams/<name>.json, written only with --if-generation-match, so a stale write fails instead of
# replacing a newer one. FXA_TEAMS_DIR caches each record with its generation (<name>.gen) and its
# prompts (<name>/), and holds index.json, which the bot and the dashboard read.
# With no FXA_GCE_PROJECT (a laptop, a check), the cache is the store.

FXA_TEAMS_URI="${FXA_TEAMS_URI-${FXA_GCE_PROJECT:+gs://${FXA_GCE_PROJECT}-fxa-ai-fixme/teams}}"
_TEAMS_PY() { FXA_RESERVED_TEAMS="$(ls "${SANDBOX_ROOT}/profiles" 2>/dev/null | tr '\n' ' ')" python3 -I "${SANDBOX_ROOT}/lib/team_record.py" "$@"; }

# _teams_actor   Who writes: FXA_TEAM_ACTOR, else the git email of this host.
_teams_actor() { printf '%s' "${FXA_TEAM_ACTOR:-$(git config user.email 2>/dev/null || true)}"; }

# _teams_remote_gen <name>   The live generation of the team's object, or nothing. Not objects list:
# the bucket keeps old versions, and list can name them too.
_teams_remote_gen() {
  gcloud storage objects describe "${FXA_TEAMS_URI}/$1.json" --format='value(generation)' 2>/dev/null
}

# teams_index   Rebuild index.json from the cached records, in one rename.
teams_index() {
  mkdir -p "$FXA_TEAMS_DIR"
  _TEAMS_PY index "$FXA_TEAMS_DIR" > "${FXA_TEAMS_DIR}/index.json.$$" && mv -f "${FXA_TEAMS_DIR}/index.json.$$" "${FXA_TEAMS_DIR}/index.json"
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

# teams_validate <file> [<name>]   The record's own rules, then its clashes with the other teams.
teams_validate() {
  local f="$1" name="${2:-}" builtin="" p
  [ -n "$name" ] || name="$(jq -r '.name // empty' "$f" 2>/dev/null)"
  _TEAMS_PY validate "$f" "$name" || return 1
  # The built-in teams' Jira projects, so a record cannot take FxA's queue.
  for p in "${SANDBOX_ROOT}"/profiles/*/profile.conf; do
    p="$( ( pipeline_load "$(basename "$(dirname "$p")")" >/dev/null 2>&1 && printf '%s:%s' "${PIPE_JIRA_PROJECT:-$([ "$PIPE_PROFILE" = fxa ] && echo FXA)}" "$PIPE_PROFILE" ) )"
    [[ "$p" =~ ^[A-Z][A-Z0-9]*: ]] && builtin="${builtin} ${p}"
  done
  FXA_BUILTIN_JIRA="$builtin" _TEAMS_PY unique "$f" "$FXA_TEAMS_DIR"
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
  _teams_pull "$name" && teams_index
}

# teams_create <file>   A new team. Refused when the name is a built-in team or already has a record.
teams_create() {
  local f="$1" name tmp rc
  name="$(jq -r '.name // empty' "$f" 2>/dev/null)"
  [[ "$name" =~ ^[a-z][a-z0-9-]{1,30}$ ]] || { echo "ERROR: the record needs a name" >&2; return 1; }
  teams_validate "$f" "$name" || return 1
  tmp="$(mktemp "${TMPDIR:-/tmp}/fxa-team.XXXXXX")"
  _TEAMS_PY stamp "$f" "$(_teams_actor)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$tmp" || { rm -f "$tmp"; return 1; }
  _teams_write "$name" "$tmp" 0; rc=$?; rm -f "$tmp"
  [ "$rc" = 2 ] && echo "ERROR: team ${name} already exists; use profile set" >&2
  [ "$rc" = 0 ] && echo "created team ${name} (generation $(cat "${FXA_TEAMS_DIR}/${name}.gen"))"
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
  teams_validate "$f" "$name" || return 1
  tmp="$(mktemp "${TMPDIR:-/tmp}/fxa-team.XXXXXX")"
  _TEAMS_PY stamp "$f" "$(_teams_actor)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${FXA_TEAMS_DIR}/${name}.json" > "$tmp" || { rm -f "$tmp"; return 1; }
  _teams_write "$name" "$tmp" "$gen"; rc=$?; rm -f "$tmp"
  [ "$rc" = 0 ] && echo "updated team ${name} (generation $(cat "${FXA_TEAMS_DIR}/${name}.gen"))"
  return $rc
}

# teams_status <name> <draft|active|disabled>
teams_status() {
  local name="$1" st="$2" tmp rc
  case "$st" in draft|active|disabled) ;; *) echo "ERROR: status is draft, active or disabled" >&2; return 1 ;; esac
  [ -f "${FXA_TEAMS_DIR}/${name}.json" ] || { echo "ERROR: no team ${name} here; run profile sync" >&2; return 1; }
  tmp="$(mktemp "${TMPDIR:-/tmp}/fxa-team.XXXXXX")"
  jq --arg s "$st" '.status = $s' "${FXA_TEAMS_DIR}/${name}.json" > "$tmp" && teams_set "$name" "$tmp"; rc=$?
  rm -f "$tmp"; return $rc
}

# teams_delete <name>   Remove a team. Refused while one of its sessions can still resume.
teams_delete() {
  local name="$1" gen f n=0
  [[ "$name" =~ ^[a-z][a-z0-9-]{1,30}$ ]] && [ ! -d "${SANDBOX_ROOT}/profiles/${name}" ] || { echo "ERROR: ${name} is not a team record" >&2; return 1; }
  for f in "$SESSION_DIR"/agent-*.json; do
    [ -f "$f" ] && [ "$(jq -r '.profile // empty' "$f" 2>/dev/null)" = "$name" ] \
      && case "$(jq -r '.state // empty' "$f")" in stopped|failed) ;; *) n=$((n + 1)) ;; esac
  done
  [ "$n" = 0 ] || { echo "ERROR: team ${name} has ${n} session(s) that can resume; stop them first" >&2; return 1; }
  gen="$(cat "${FXA_TEAMS_DIR}/${name}.gen" 2>/dev/null)"
  if [ -n "$FXA_TEAMS_URI" ]; then
    [[ "$gen" =~ ^[0-9]+$ ]] || { echo "ERROR: no generation for team ${name}; run profile sync" >&2; return 1; }
    gcloud storage rm -q "${FXA_TEAMS_URI}/${name}.json" --if-generation-match="$gen" >/dev/null 2>&1 \
      || { echo "ERROR: could not delete team ${name} (changed since generation ${gen}?); run profile sync" >&2; return 1; }
  fi
  rm -rf "${FXA_TEAMS_DIR:?}/${name}.json" "${FXA_TEAMS_DIR:?}/${name}.gen" "${FXA_TEAMS_DIR:?}/${name}"
  teams_index && echo "deleted team ${name}"
}

# teams_sync   Make the cache match the bucket: every record at its current generation, none extra.
teams_sync() {
  [ -n "$FXA_TEAMS_URI" ] || { teams_index; echo "no team store (FXA_GCE_PROJECT is unset): the cache is the store"; return 0; }
  local names n f
  # ls names live objects only (objects list also names a deleted team's old versions).
  # An empty store is not an error: GCS says "matched no objects".
  if ! names="$(gcloud storage ls "${FXA_TEAMS_URI}/*.json" 2>&1)"; then
    grep -qi 'matched no objects' <<< "$names" || { echo "ERROR: could not list ${FXA_TEAMS_URI}: $(tail -1 <<< "$names")" >&2; return 1; }
    names=""
  fi
  names="$(printf '%s\n' "$names" | sed -n 's#^.*/##; s#\.json$##p' | grep -E '^[a-z][a-z0-9-]{1,30}$' | sort -u || true)"
  for n in $names; do _teams_pull "$n" || echo "WARN: could not fetch team ${n}" >&2; done
  for f in "$FXA_TEAMS_DIR"/*.json; do
    n="$(basename "$f" .json)"; [ -f "$f" ] && [ "$n" != index ] || continue
    grep -qx "$n" <<< "$names" || { rm -rf "${FXA_TEAMS_DIR:?}/${n}.json" "${FXA_TEAMS_DIR:?}/${n}.gen" "${FXA_TEAMS_DIR:?}/${n}"; echo "removed team ${n} (no longer in the store)"; }
  done
  teams_index && echo "teams: $(printf '%s\n' "$names" | grep -c . || true) in the store"
}
