#!/bin/bash
# jira.sh: Fetch Jira issue context via acli and render it as markdown.
#
# Public API:
#   jira_fetch_context <ISSUE-KEY>   Prints a markdown context blob to stdout.
#   jira_slug_for <ISSUE-KEY>        Prints a lowercased slug from the issue summary.

[ -n "${_FXA_JIRA_LOADED:-}" ] && return 0
_FXA_JIRA_LOADED=1

# Render Jira's rich-text JSON (Atlassian Document Format) as markdown.
read -r -d '' _JIRA_ADF_JQ <<'JQ' || true
def adf:
  if type == "object" then
    if   .type == "text"        then (.text // "")
    elif .type == "hardBreak"   then "\n"
    elif .type == "paragraph"   then ((.content // []) | map(adf) | add // "") + "\n\n"
    elif .type == "heading"     then ("#" * (.attrs.level // 1)) + " " + ((.content // []) | map(adf) | add // "") + "\n\n"
    elif .type == "bulletList"  then ((.content // []) | map("- " + adf) | add // "") + "\n"
    elif .type == "orderedList" then ((.content // []) | map("1. " + adf) | add // "") + "\n"
    elif .type == "listItem"    then ((.content // []) | map(adf) | add // "") | sub("\n\n$"; "\n")
    elif .type == "codeBlock"   then "```" + (.attrs.language // "") + "\n" + ((.content // []) | map(adf) | add // "") + "\n```\n\n"
    elif .type == "blockquote"  then "> " + ((.content // []) | map(adf) | add // "") + "\n"
    elif .type == "rule"        then "\n---\n\n"
    elif .type == "mention"     then (.attrs.text // "")
    elif .type == "inlineCard"  then (.attrs.url // "")
    elif .type == "emoji"       then (.attrs.shortName // "")
    elif .type == "mediaSingle" or .type == "media" or .type == "mediaGroup" then ""
    else ((.content // []) | map(adf) | add // "")
    end
  elif type == "array" then (map(adf) | add // "")
  else "" end;

. as $issue
| $issue.fields as $f
| ($f.description | adf) as $desc
| ($f.comment.comments // []) as $comments

| "# \($issue.key): \($f.summary)\n\n"
+ "**Type:** \($f.issuetype.name // "Unknown")  \n"
+ "**Status:** \($f.status.name // "Unknown")  \n"
+ (if $f.priority then "**Priority:** \($f.priority.name)  \n" else "" end)
+ (if $f.assignee then "**Assignee:** \($f.assignee.displayName)  \n" else "" end)
+ (if ($f.labels // []) | length > 0 then "**Labels:** \($f.labels | join(", "))  \n" else "" end)
+ (if ($f.components // []) | length > 0 then "**Components:** \($f.components | map(.name) | join(", "))  \n" else "" end)
+ (if $f.parent then "**Parent:** \($f.parent.key) — \($f.parent.fields.summary // "")  \n" else "" end)
+ "\n"
+ (if ($desc | length) > 0 then "## Description\n\n\($desc)\n" else "" end)
+ (if ($f.issuelinks // []) | length > 0 then
    "## Linked Issues\n\n"
    + (($f.issuelinks // [])
       | map(
           (.type.outward // .type.inward // "relates to") as $rel
           | (.outwardIssue // .inwardIssue) as $li
           | if $li then "- **\($rel)**: \($li.key) — \($li.fields.summary // "")\n" else "" end
         )
       | add // "")
    + "\n"
   else "" end)
+ (if ($comments | length) > 0 then
    "## Comments (\($comments | length))\n\n"
    + ($comments
       | map(
           "### \(.author.displayName // "Unknown") — \(.created // "")\n\n"
           + (.body | adf)
           + "\n"
         )
       | add // "")
   else "" end)
JQ

# Slug from the summary, for branch and worktree names.
read -r -d '' _JIRA_SLUG_JQ <<'JQ' || true
.fields.summary
| ascii_downcase
| gsub("[^a-z0-9]+"; "-")
| gsub("^-+|-+$"; "")
| .[0:50]
| gsub("-+$"; "")
JQ

# acli as the loaded team: a team with its own Jira credential has its own acli login, in its home.
# An Atlassian service account's token works only through the API gateway, and acli logs in only on
# the site, so for one the same calls go to REST and print what acli prints.
# acli keeps config.sh's _retry: one failed call made precheck report a refused login.
# A write that must not repeat (a create) calls _acli_once.
_acli_once() {
  if _jira_sa; then _acli_rest "$@"
  elif [ -n "${FXA_ACLI_HOME:-}" ]; then HOME="$FXA_ACLI_HOME" command acli "$@"; else command acli "$@"; fi
}
acli() { _retry _acli_once "$@"; }


# _jira_rest <method> <path> [curl args]   The body on stdout; an HTTP error returns nonzero.
_jira_rest() {
  local m="$1" p="$2" base; shift 2; base="$(_jira_api)" || return 1
  printf 'user = "%s"\n' "$PIPE_JIRA_BASIC" | curl -sSf -K - --max-time 30 -X "$m" -H 'Accept: application/json' "$@" "${base}${p}" 2>/dev/null
}
_jira_rest_json() { local m="$1" p="$2"; shift 2; _jira_rest "$m" "$p" -H 'Content-Type: application/json' --data "$@"; }

JIRA_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ADF as acli's plain text.
read -r -d '' _JIRA_TEXT_JQ <<'JQ' || true
def txt:
  if type == "object" then
    if   .type == "text"      then (.text // "")
    elif .type == "hardBreak" then "\n"
    elif .type == "mention"   then (.attrs.text // "")
    elif .type == "inlineCard" then (.attrs.url // "")
    elif .type == "emoji"     then (.attrs.text // .attrs.shortName // "")
    elif (.type | IN("paragraph", "heading", "listItem", "codeBlock", "blockquote")) then ((.content // []) | map(txt) | add // "") + "\n"
    else ((.content // []) | map(txt) | add // "") end
  elif type == "array" then (map(txt) | add // "")
  else "" end;
JQ

# _acli_rest <acli args>   The acli subcommands this controller uses, on Jira's REST API.
_acli_rest() {
  local a="$1 $2 ${3:-}" key="" fields="" jql="" limit=50 json=0 body="" status="" project="" type="" summary="" desc="" label="" add="" rm="" assignee="" id="" state="" all_pages=0
  shift 2; [[ "$a" == "jira workitem comment" ]] && shift
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --key|-k) key="$2"; shift ;; --fields) fields="$2"; shift ;; --jql) jql="$2"; shift ;; --limit) limit="$2"; shift ;;
      --json) json=1 ;; -y|--yes) ;; --body) body="$2"; shift ;; --status) status="$2"; shift ;;
      --project) project="$2"; shift ;; --type) type="$2"; shift ;; --summary) summary="$2"; shift ;;
      --description-file) desc="$(cat "$2")" || return 1; shift ;; --label) label="$2"; shift ;;
      -l|--labels) add="$2"; shift ;; --remove-labels) rm="$2"; shift ;; --assignee) assignee="$2"; shift ;;
      --id) id="$2"; shift ;; --state) state="$2"; shift ;; --paginate) all_pages=1 ;;
      -*) echo "acli (service account): $1 is not supported" >&2; return 1 ;;
      *) key="$1" ;;
    esac; shift
  done
  local doc='{type: "doc", version: 1, content: [{type: "paragraph", content: [{type: "text", text: $t}]}]}' out
  case "$a" in
    "jira auth status")
      out="$(_jira_rest GET /rest/api/3/myself)" || { echo "✗ unauthorized"; return 1; }
      printf '✓ Authenticated\n  Account: %s\n' "$(jq -r '.displayName' <<< "$out")" ;;
    "jira workitem view")
      if [ "$json" = 1 ]; then
        _jira_rest GET "/rest/api/3/issue/${key}?fields=${fields:-*navigable}"
      else
        out="$(_jira_rest GET "/rest/api/3/issue/${key}?fields=issuetype,summary,status,description")" || return 1
        jq -r "${_JIRA_TEXT_JQ}"' "Key: \(.key)\nType: \(.fields.issuetype.name)\nSummary: \(.fields.summary)\nStatus: \(.fields.status.name)\nDescription: \(.fields.description | txt | sub("\n+$"; ""))"' <<< "$out"
      fi ;;
    "jira workitem comment")
      case "${body:+create}" in
        # A body that is already an ADF doc (jira_comment's) goes as it is.
        create) _jira_rest_json POST "/rest/api/3/issue/${key}/comment" "$(jq -nc --arg t "$body" "{body: ((\$t | try fromjson catch null) as \$j | if (\$j | type) == \"object\" and \$j.type == \"doc\" then \$j else $doc end)}")" >/dev/null ;;
        # One object per page, as acli --paginate prints them; without it, the first page only.
        *) local at=0
           while :; do
             out="$(_jira_rest GET "/rest/api/3/issue/${key}/comment?maxResults=50&startAt=${at}")" || return 1
             jq "${_JIRA_TEXT_JQ}"' {comments: [.comments[] | {author: .author.displayName, body: (.body | txt | sub("\n+$"; "")), id, visibility: "public"}], isLast: (.startAt + (.comments | length) >= .total), maxResults, startAt, total}' <<< "$out" || return 1
             at=$((at + $(jq '.comments | length' <<< "$out")))
             [ "$all_pages" = 1 ] && [ "$at" -lt "$(jq '.total' <<< "$out")" ] && [ "$(jq '.comments | length' <<< "$out")" -gt 0 ] || break
           done ;;
      esac ;;
    "jira workitem search")
      local tok="" page all="[]"
      while :; do
        page="$(_jira_rest_json POST /rest/api/3/search/jql "$(jq -nc --arg q "$jql" --arg f "${fields:-issuetype,assignee,priority,status,summary}" --arg t "$tok" \
          --argjson n "$(( limit > 100 ? 100 : limit ))" '{jql: $q, maxResults: $n, fields: ($f | split(","))} + (if $t != "" then {nextPageToken: $t} else {} end)')")" || return 1
        # On stdin, not --argjson: Linux refuses one argument over 128 KiB, and a page of 100 issues can be.
        all="$(printf '%s\n%s\n' "$all" "$page" | jq -cs --argjson n "$limit" '(.[0] + (.[1].issues // []))[0:$n]')" || return 1
        tok="$(jq -r '.nextPageToken // empty' <<< "$page")"
        [ -n "$tok" ] && [ "$(jq length <<< "$all")" -lt "$limit" ] || break
      done
      printf '%s\n' "$all" ;;
    "jira workitem edit")
      if [ -n "$add$rm" ]; then
        _jira_rest_json PUT "/rest/api/3/issue/${key}" "$(jq -nc --arg a "$add" --arg r "$rm" \
          '{update: {labels: ([$r | split(",")[] | select(. != "") | {remove: .}] + [$a | split(",")[] | select(. != "") | {add: .}])}}')" >/dev/null || return 1
      fi
      if [ -n "$assignee" ]; then
        id="$(_jira_rest GET /rest/api/3/user/search -G --data-urlencode "query=${assignee}" | jq -r 'if length == 1 then .[0].accountId else empty end')"
        [ -n "$id" ] || { echo "acli (service account): no single Jira user for ${assignee}" >&2; return 1; }
        _jira_rest_json PUT "/rest/api/3/issue/${key}/assignee" "$(jq -nc --arg i "$id" '{accountId: $i}')" >/dev/null
      fi ;;
    "jira workitem transition")
      id="$(_jira_rest GET "/rest/api/3/issue/${key}/transitions" | jq -r --arg s "$status" '[.transitions[] | select(.to.name == $s or .name == $s) | .id][0] // empty')"
      [ -n "$id" ] || { echo "acli (service account): $key has no transition to ${status}" >&2; return 1; }
      _jira_rest_json POST "/rest/api/3/issue/${key}/transitions" "$(jq -nc --arg i "$id" '{transition: {id: $i}}')" >/dev/null ;;
    "jira workitem create")
      out="$(jq -nc --arg t "$desc" "$doc")"
      _jira_rest_json POST /rest/api/3/issue "$(jq -nc --arg p "$project" --arg y "$type" --arg s "$summary" --argjson d "$out" --arg l "$label" \
        '{fields: ({project: {key: $p}, issuetype: {name: $y}, summary: $s, description: $d} + (if $l != "" then {labels: [$l]} else {} end))}')" ;;
    "jira board list-sprints")
      out="$(_jira_rest GET "/rest/agile/1.0/board/${id}/sprint?state=${state:-active}")" || return 1
      jq '{sprints: .values, isLast, maxResults, startAt, total: (.total // (.values | length))}' <<< "$out" ;;
    *) echo "acli (service account): '$a' is not supported" >&2; return 1 ;;
  esac
}

_jira_require_acli() {
  if ! command -v acli &>/dev/null; then
    echo "ERROR: acli is not installed. Install with: brew install --cask atlassian-cli" >&2
    return 1
  fi
  if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is not installed. Install with: brew install jq" >&2
    return 1
  fi
}

# Cache the issue JSON for this shell, so context and slug cost one API call.
_JIRA_CACHE_DIR="${TMPDIR:-/tmp}/fxa-sandbox-ctl-jira-$$"
_jira_fetch_raw() {
  local key="$1"
  _jira_require_acli || return 1
  mkdir -p "${_JIRA_CACHE_DIR}"
  local cache="${_JIRA_CACHE_DIR}/${key}.json"
  if [ ! -s "$cache" ]; then
    if ! acli jira workitem view "$key" --json --fields "*all" > "${cache}.tmp" 2>/dev/null; then
      rm -f "${cache}.tmp"
      echo "ERROR: Failed to fetch ${key} from Jira. Check 'acli jira auth status'." >&2
      return 1
    fi
    mv "${cache}.tmp" "$cache"
  fi
  cat "$cache"
}

# jira_fetch_context <ISSUE-KEY>: emit a markdown context blob to stdout.
jira_fetch_context() {
  local key="${1:-}"
  if [ -z "$key" ]; then
    echo "ERROR: jira_fetch_context requires an issue key (e.g. FXA-1234)" >&2
    return 1
  fi
  local json
  json="$(_jira_fetch_raw "$key")" || return 1
  printf '%s' "$json" | jq -r "${_JIRA_ADF_JQ}"
}

# jira_slug_for <ISSUE-KEY>: emit a lowercased slug (max 50 chars) from the summary.
jira_slug_for() {
  local key="${1:-}"
  if [ -z "$key" ]; then
    echo "ERROR: jira_slug_for requires an issue key" >&2
    return 1
  fi
  local json
  json="$(_jira_fetch_raw "$key")" || return 1
  printf '%s' "$json" | jq -r "${_JIRA_SLUG_JQ}"
}

# jira_summary_for <ISSUE-KEY>: emit just the summary string.
jira_summary_for() {
  local key="${1:-}"
  if [ -z "$key" ]; then
    echo "ERROR: jira_summary_for requires an issue key" >&2
    return 1
  fi
  local json
  json="$(_jira_fetch_raw "$key")" || return 1
  printf '%s' "$json" | jq -r '.fields.summary'
}

# jira_normalize_key <KEY>: uppercase the project prefix, validate shape.
# jira_card <KEY>   One JSON line for a Slack card: summary, status, assignee, type,
# priority. Prints null for a ticket Slack must not show: another project, a security
# level, or a HackerOne or security label (the MCP gateway's rule).
jira_card() {
  local key out; key="$(jira_normalize_key "${1:-}")" || return 1
  out="$(acli jira workitem view "$key" --fields summary,status,assignee,labels,security,issuetype,priority --json 2>/dev/null \
    | jq -c --arg p "${FXA_JIRA_CARD_PROJECT:-FXA}" '
        if (.key | startswith($p + "-") | not) or .fields.security != null
           or ([.fields.labels[]? | ascii_downcase] | any(. == "hackerone" or . == "security")) then null
        else {key, summary: .fields.summary, status: .fields.status.name, category: .fields.status.statusCategory.key,
              assignee: .fields.assignee.displayName, type: .fields.issuetype.name, priority: .fields.priority.name} end' \
    2>/dev/null)" || true
  printf '%s\n' "${out:-null}"
}

jira_normalize_key() {
  local key="${1:-}"
  key="$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')"
  if ! [[ "$key" =~ ^[A-Z]+-[0-9]+$ ]]; then
    echo "ERROR: '${1:-}' is not a valid Jira issue key (expected e.g. FXA-1234)" >&2
    return 1
  fi
  printf '%s\n' "$key"
}

trap 'rm -rf "${_JIRA_CACHE_DIR}" 2>/dev/null' EXIT

# ── Pipeline queries ───────────────────────────────────────────
# These read and write the ai-fixme label family, which IS the pipeline's state
# machine. They need a loaded pipeline config (see lib/pipeline.sh).

# jira_login_ok   acli's Jira login works. An expired API token is refused at once, and every
# Jira read then prints an error in place of JSON.
jira_login_ok() {
  local out; out="$(acli jira auth status 2>&1)" || true
  case "$out" in *Authenticated*) return 0 ;; esac
  return 1
}

_jira_keys_for_jql() {
  acli jira workitem search --jql "$1" --limit 200 --json 2>/dev/null \
    | jq -r '.[]?.key // empty'
}

# Keys waiting in the queue, oldest first.
jira_queue_keys() {
  pipeline_require || return 1
  local q; q="$(pipeline_queue_jql)" || return 1
  _jira_keys_for_jql "$q"
}

# Keys in one lifecycle state, oldest first.
jira_keys_in_state() {
  pipeline_require || return 1
  local label s; label="$(pipeline_label_for "${1:?state required}")"; s="$(pipeline_jira_scope)" || return 1
  _jira_keys_for_jql "${s} AND labels = \"${label}\" ORDER BY created ASC"
}

jira_inflight_keys()  { jira_keys_in_state inflight; }

# jira_items_json <JQL>
#   Key and summary for every match, as JSON. Same one call as the key-only
#   reads, with one more field, so the dashboard costs no extra API request.
#   Prints `null` on failure, which the caller must not confuse with `[]`.
jira_items_json() {
  local raw rc=0
  raw="$(acli jira workitem search --jql "$1" --limit 200 --fields key,summary --json 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$raw" ]; then echo 'null'; return 0; fi
  printf '%s' "$raw" | jq '[.[]? | {key, summary: (.fields.summary // "")}]' 2>/dev/null || echo 'null'
}

jira_queue_items()    { pipeline_require || return 1; local q; q="$(pipeline_queue_jql)" || return 1; jira_items_json "$q"; }
# jira_items_in_state <state> [extra JQL]   The state's items; the extra clause narrows them (the dashboard's blocked list).
jira_items_in_state() {
  pipeline_require || return 1
  local s; s="$(pipeline_jira_scope)" || return 1
  jira_items_json "${s} AND labels = \"$(pipeline_label_for "${1:?state required}")\"${2:+ AND $2} ORDER BY created ASC"
}
jira_done_keys()      { jira_keys_in_state done; }
# jira_secured_keys   The project's pipeline tickets that got a security level or a secret label: the
# scoped state reads no longer see them, so their label stays until a person moves them.
# A secret team: its own tickets that lost their level and secret label. A public team: with a team that
# takes the project's secret tickets, a queued one is that team's work; with none, that team's labels too.
jira_secured_keys() {
  pipeline_require || return 1
  local p ls="" st sl s; p="$(pipeline_jira_project)" || return 1; sl="$(_pipeline_secret_labels)" || return 1
  pipeline_jira_scope >/dev/null || return 1
  if [ "${PIPE_SECRET_TICKETS:-}" = 1 ]; then
    for st in $(pipeline_states); do [ "$st" = public ] || ls="${ls:+$ls, }\"$(pipeline_label_for "$st")\""; done
    _jira_keys_for_jql "project = ${p} AND level IS EMPTY AND (labels IS EMPTY OR labels NOT IN (${sl})) AND labels in (${ls})"
    return
  fi
  s="$(pipeline_secret_team "$p")"
  for st in $(pipeline_states); do
    [ -n "$s" ] && [ "$st" = public ] && continue
    ls="${ls:+$ls, }\"$(pipeline_label_for "$st")\""
    # ai-fixme-private: the prefix team_record.py gives a secret team.
    [ -n "$s" ] || [ "$st" = public ] || ls="${ls}, \"ai-fixme-private-${st}\""
  done
  _jira_keys_for_jql "project = ${p} AND (level IS NOT EMPTY OR labels IN (${sl})) AND labels in (${ls})"
}

# jira_owning_keys
#   The keys that still own a pool slot. A ticket owns its slot from the launch
#   until its label leaves `inflight`, even though its VM is stopped once the PR
#   opens. Prints UNKNOWN when the query fails, so a caller can fail closed
#   instead of treating "no owners" as "every slot is claimable".
jira_owning_keys() {
  local out rc=0
  out="$(jira_inflight_keys)" || rc=$?
  if [ "$rc" -ne 0 ]; then printf 'UNKNOWN\n'; return 0; fi
  printf '%s\n' "$out" | tr '[:lower:]' '[:upper:]'
}

# jira_label_set <KEY> <STATE>
#   WRITE: swap the label family to <STATE>. acli replaces the label set named
#   by -l, so remove the other states explicitly or a ticket ends up in two
#   states at once.
#
#   This does the label write only. Reaping the VM and reacting to review
#   comments are the caller's job (see cmd_label), because they are not Jira.
jira_label_set() {
  pipeline_require || return 1
  local key="${1:-}" state="${2:-}"
  [ -n "$key" ] && [ -n "$state" ] || { echo "ERROR: label needs <KEY> <state>" >&2; return 1; }
  # Accept the full label too. Callers reach for `ai-fixme-blocked` as often as
  # `blocked`, and failing on the longer form is pointless friction.
  [ "$state" = "$PIPE_LABEL_PREFIX" ] || [ "$state" = "${PIPE_QUEUE_LABEL:-$PIPE_LABEL_PREFIX}" ] && state="public"
  state="${state#${PIPE_LABEL_PREFIX}-}"
  case "$state" in
    public|queued|inflight|done|blocked|merged|rejected|diff) ;;
    *) echo "ERROR: bad state '$state'" >&2; return 1 ;;
  esac
  local want; want="$(pipeline_label_for "$state")"
  # The other family's states too (a public team's and a secret team's ai-fixme-private-*): a ticket
  # that changed sides keeps one state label, the one this write sets.
  local others="" s l alt="${PIPE_QUEUE_LABEL:-$PIPE_LABEL_PREFIX}"
  [ "$alt" != "$PIPE_LABEL_PREFIX" ] || alt="${PIPE_LABEL_PREFIX}-private"
  while IFS= read -r s; do
    l="$(pipeline_label_for "$s")"
    [ "$l" = "$want" ] || others="${others}${others:+,}${l}"
    [ "$s" = public ] || [ "${alt}-${s}" = "$want" ] || others="${others},${alt}-${s}"
  done <<< "$(pipeline_states)"
  acli jira workitem edit -k "$key" --remove-labels "$others" -l "$want" -y >/dev/null
  printf '%s -> %s\n' "$key" "$want"
}

# Ticket text INCLUDING comments. `acli jira workitem view` silently omits
# comments, where reporters often answer the open questions. Ground with this.
jira_ticket() {
  local key="${1:-}"; [ -n "$key" ] || { echo "ERROR: ticket needs <KEY>" >&2; return 1; }
  echo "=== $key description ==="
  # Under set -e a refused view used to end the command with only the header; say why and stop.
  acli jira workitem view "$key" 2>/dev/null || { echo "ERROR: Jira did not return ${key}: it is restricted, missing, or the Jira login failed." >&2; return 1; }
  echo
  echo "=== $key comments (oldest first) ==="
  acli jira workitem comment list --key "$key" --json --paginate 2>/dev/null \
    | jq -r '.comments[]? | "--- \(.author) [\(.id)]\n\(.body)\n"' \
    || echo "(none)"
}

# jira_reporter_login <KEY>
#   Print the GitHub login of whoever filed the ticket, from reporters.tsv in
#   the state directory, or nothing. Never guesses. Match on displayName, the
#   real name on both sides: an email local-part does not predict the handle.
jira_reporter_login() {
  pipeline_require || return 1
  local key="${1:-}"; [ -n "$key" ] || { echo "ERROR: reporter needs <KEY>" >&2; return 1; }
  local map="${PIPE_STATE_DIR}/reporters.tsv"
  [ -f "$map" ] || return 0
  local name
  name="$(acli jira workitem search --jql "key = ${key}" --fields key,reporter --json 2>/dev/null \
    | jq -r '.[0].fields.reporter.displayName // empty' 2>/dev/null)" || name=""
  [ -n "$name" ] || return 0
  awk -F'\t' -v n="$name" '$0 !~ /^#/ && $1 == n {print $2; exit}' "$map"
}

# jira_login_email <GITHUB_LOGIN>
#   Read reporters.tsv in the other direction: GitHub login -> Jira email. Empty
#   when the login has no row or no address, and the caller then leaves the
#   ticket unassigned. Never guesses an address from the login.
jira_login_email() {
  pipeline_require || return 1
  local login="${1:-}"; [ -n "$login" ] || return 0
  local map="${PIPE_STATE_DIR}/reporters.tsv"
  [ -f "$map" ] || return 0
  awk -F'\t' -v l="$login" '$0 !~ /^#/ && $2 == l {print $3; exit}' "$map"
}

# jira_active_sprint_id
#   Print the id of the board's active sprint named by PIPE_JIRA_SPRINT_MATCH.
#   Prints nothing unless exactly one sprint matches: board 225 runs an FxA and a
#   SubPlat sprint at the same time, so "the active sprint" is not a single thing
#   and picking the first would file FxA work into the SubPlat train.
jira_active_sprint_id() {
  pipeline_require || return 1
  [ -n "${PIPE_JIRA_BOARD:-}" ] || return 0
  acli jira board list-sprints --id "$PIPE_JIRA_BOARD" --state active --json 2>/dev/null \
    | jq -r --arg re "${PIPE_JIRA_SPRINT_MATCH:-.}" \
        '[.sprints[]? | select(.name | test($re)) | .id] | if length == 1 then .[0] else empty end'
}

# jira_sprint_add <KEY> <SPRINT_ID>
#   WRITE: put the ticket in the sprint. acli cannot write the Sprint field, so
#   this is the one direct REST call and the only one that needs a Jira API
#   token. Without PIPE_JIRA_BASIC it warns and returns 0: an unsprinted ticket
#   is a smaller problem than a merge close that aborts.
jira_sprint_add() {
  pipeline_require || return 1
  local key="${1:-}" sid="${2:-}"
  [ -n "$key" ] && [ -n "$sid" ] || return 0
  if [ -z "${PIPE_JIRA_BASIC:-}" ]; then
    echo "WARN: PIPE_JIRA_BASIC unset; $key not added to sprint $sid" >&2
    return 0
  fi
  local code
  # The login goes in on stdin (-K -), never on curl's command line, where ps shows it.
  code="$(printf 'user = "%s"\n' "$PIPE_JIRA_BASIC" | curl -sS -K - -o /dev/null -w '%{http_code}' \
            -X POST -H 'Content-Type: application/json' \
            --data "$(jq -nc --arg k "$key" '{issues: [$k]}')" \
            "$(_jira_api)/rest/agile/1.0/sprint/${sid}/issue" 2>/dev/null)" || code="000"
  [ "$code" = "204" ] || echo "WARN: sprint add for $key returned HTTP $code" >&2
}

# jira_attach <KEY> <file>   WRITE: attach a file to the ticket. acli cannot upload, so this calls
#   Jira's REST API. The login goes to curl on stdin, so `ps` never shows it. A POST: no retry.
jira_attach() {
  [[ "${1:-}" =~ ^[A-Z][A-Z0-9]*-[0-9]+$ ]] && [ -s "${2:-}" ] || { echo "usage: jira_attach <KEY> <file>" >&2; return 1; }
  [ -n "${PIPE_JIRA_BASIC:-}" ] || { echo "WARN: PIPE_JIRA_BASIC unset; nothing attached to $1" >&2; return 1; }
  local code
  code="$(printf 'user = "%s"\n' "$PIPE_JIRA_BASIC" | curl -sS -K - -o /dev/null -w '%{http_code}' -X POST \
            -H 'X-Atlassian-Token: no-check' -F "file=@${2}" "$(_jira_api)/rest/api/3/issue/${1}/attachments" 2>/dev/null)" || code=000
  [ "$code" = 200 ] || { echo "WARN: attaching ${2##*/} to $1 returned HTTP $code" >&2; return 1; }
}

# _jira_rest_get <path>   A GET on Jira's REST API; the login goes to curl on stdin.
_jira_rest_get() {
  printf 'user = "%s"\n' "$PIPE_JIRA_BASIC" | curl -sSf -K - --max-time 20 -H 'Accept: application/json' "$(_jira_api)$1" 2>/dev/null
}

# jira_close_merged <KEY>
#   WRITE: finish a merged ticket the way a person would. Assign the reviewer who
#   approved, add it to the active sprint, transition it to Done.
#   Assignee and sprint are set ONLY when empty, because a human's choice wins.
#   Every step warns and continues: a failed label write would do more harm
#   than the cosmetic gap this fixes.
jira_close_merged() {
  pipeline_require || return 1
  local key="${1:-}"; [ -n "$key" ] || { echo "ERROR: close needs <KEY>" >&2; return 1; }
  local cur; cur="$(acli jira workitem view "$key" --json --fields "*all" 2>/dev/null)"

  if [ -z "$(printf '%s' "$cur" | jq -r '.fields.assignee.accountId // empty' 2>/dev/null)" ]; then
    local login email
    login="$(gh_pr_approver "$key" 2>/dev/null)"
    email="$(jira_login_email "$login" 2>/dev/null)"
    if [ -n "$email" ]; then
      acli jira workitem edit -k "$key" --assignee "$email" -y >/dev/null 2>&1 \
        || echo "WARN: assigning $key to $email failed" >&2
    else
      echo "WARN: $key approver '${login:-none}' has no reporters.tsv email; left unassigned" >&2
    fi
  fi

  local field="${PIPE_JIRA_SPRINT_FIELD:-customfield_10020}"
  if [ "$(printf '%s' "$cur" | jq -r --arg f "$field" '(.fields[$f] // []) | length' 2>/dev/null)" = "0" ]; then
    local sid; sid="$(jira_active_sprint_id)"
    [ -n "$sid" ] && jira_sprint_add "$key" "$sid"
  fi

  acli jira workitem transition --key "$key" --status "${PIPE_JIRA_DONE_STATUS:-Done}" -y >/dev/null 2>&1 \
    || echo "WARN: transition of $key to ${PIPE_JIRA_DONE_STATUS:-Done} failed" >&2
  jira_record_state "$key" || true
}

# jira_start_work <KEY>
#   WRITE: a ticket the agent starts on moves from To Do to PIPE_JIRA_START_STATUS. Only from the
#   To Do category: a fix round must not move a ticket back from review. A failure warns only.
jira_start_work() {
  local key="${1:-}" cat
  cat="$(acli jira workitem view "$key" --fields status --json 2>/dev/null | jq -r '.fields.status.statusCategory.key // empty' 2>/dev/null)"
  [ "$cat" = new ] || return 0
  acli jira workitem transition --key "$key" --status "${PIPE_JIRA_START_STATUS:-In Progress}" -y >/dev/null 2>&1 \
    || echo "WARN: transition of $key to ${PIPE_JIRA_START_STATUS:-In Progress} failed" >&2
}

# jira_record_state <KEY>   The ticket's assignee and status, read back from Jira, in <KEY>.jira.json
# for the Stats PRs tab. A failed read writes nothing, so the tab says the ticket is not updated.
jira_record_state() {
  local f="${PIPE_STATE_DIR}/$1.jira.json" j
  j="$(acli jira workitem view "$1" --fields assignee,status --json 2>/dev/null \
    | jq -c --arg at "$(date -u +%FT%TZ)" '{assignee: (.fields.assignee.displayName // null), status: (.fields.status.name // null), at: $at}' 2>/dev/null)" || return 1
  [ -n "$j" ] && printf '%s\n' "$j" > "$f"
}

# jira_comment <KEY> <BODY>
#   WRITE: post one comment, written in jira_adf.py's Markdown subset and sent as ADF.
#   The service account's name says a pipeline wrote it; a person's login gets 🤖 in front.
jira_comment() {
  pipeline_require || return 1
  local key="${1:-}" body="${2:-}" adf
  [ -n "$key" ] && [ -n "$body" ] || { echo "ERROR: comment needs <KEY> <body>" >&2; return 1; }
  adf="$(printf '%s' "$body" | python3 -I "${JIRA_LIB_DIR}/jira_adf.py" $(_jira_sa || echo --mark))" || return 1
  acli jira workitem comment create --key "$key" --body "$adf" >/dev/null
}
