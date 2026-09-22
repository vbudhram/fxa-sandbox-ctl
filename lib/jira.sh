#!/bin/bash
# jira.sh — Fetch Jira issue context via acli and render it as markdown.
#
# Public API:
#   jira_fetch_context <ISSUE-KEY>   Prints a markdown context blob to stdout.
#   jira_slug_for <ISSUE-KEY>        Prints a lowercased slug from the issue summary.

[ -n "${_FXA_JIRA_LOADED:-}" ] && return 0
_FXA_JIRA_LOADED=1

# jq program that walks an Atlassian Document Format (ADF) tree and emits markdown.
# ADF is a nested JSON structure used by Jira for rich text fields (description, comments).
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

# Read the workitem summary (used to derive a slug for branch / worktree names).
read -r -d '' _JIRA_SLUG_JQ <<'JQ' || true
.fields.summary
| ascii_downcase
| gsub("[^a-z0-9]+"; "-")
| gsub("^-+|-+$"; "")
| .[0:50]
| gsub("-+$"; "")
JQ

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

# jira_fetch_raw <ISSUE-KEY> — fetch the issue JSON and cache it for the lifetime
# of the current shell so we don't hit the API twice when callers want both
# context and slug.
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

# jira_fetch_context <ISSUE-KEY> — emit a markdown context blob to stdout.
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

# jira_slug_for <ISSUE-KEY> — emit a lowercased slug (max 50 chars) from the summary.
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

# jira_summary_for <ISSUE-KEY> — emit just the summary string.
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

# jira_normalize_key <KEY> — uppercase the project prefix, validate shape.
jira_normalize_key() {
  local key="${1:-}"
  key="$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')"
  if ! [[ "$key" =~ ^[A-Z]+-[0-9]+$ ]]; then
    echo "ERROR: '${1:-}' is not a valid Jira issue key (expected e.g. FXA-1234)" >&2
    return 1
  fi
  printf '%s\n' "$key"
}

# Clean up cache on shell exit
trap 'rm -rf "${_JIRA_CACHE_DIR}" 2>/dev/null' EXIT

# ── Pipeline queries ───────────────────────────────────────────
# These read and write the ai-fixme label family, which IS the pipeline's state
# machine. They need a loaded pipeline config (see lib/pipeline.sh).

_jira_keys_for_jql() {
  acli jira workitem search --jql "$1" --limit 200 --json 2>/dev/null \
    | jq -r '.[]?.key // empty'
}

# Keys waiting in the queue, oldest first.
jira_queue_keys() {
  pipeline_require || return 1
  _jira_keys_for_jql "$(pipeline_queue_jql)"
}

# Keys in one lifecycle state, oldest first.
jira_keys_in_state() {
  pipeline_require || return 1
  local label; label="$(pipeline_label_for "${1:?state required}")"
  _jira_keys_for_jql "labels = \"${label}\" ORDER BY created ASC"
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

jira_queue_items()    { pipeline_require || return 1; jira_items_json "$(pipeline_queue_jql)"; }
jira_items_in_state() {
  pipeline_require || return 1
  jira_items_json "labels = \"$(pipeline_label_for "${1:?state required}")\" ORDER BY created ASC"
}
jira_done_keys()      { jira_keys_in_state done; }

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
  [ "$state" = "$PIPE_LABEL_PREFIX" ] && state="public"
  state="${state#${PIPE_LABEL_PREFIX}-}"
  case "$state" in
    public|queued|inflight|done|blocked|merged|rejected) ;;
    *) echo "ERROR: bad state '$state'" >&2; return 1 ;;
  esac
  local want; want="$(pipeline_label_for "$state")"
  local others="" s l
  while IFS= read -r s; do
    l="$(pipeline_label_for "$s")"
    [ "$l" = "$want" ] || others="${others}${others:+,}${l}"
  done <<< "$(pipeline_states)"
  acli jira workitem edit -k "$key" --remove-labels "$others" -l "$want" -y >/dev/null
  printf '%s -> %s\n' "$key" "$want"
}

# Ticket text INCLUDING comments. `acli jira workitem view` omits comments
# entirely and says nothing about it, so grounding that used `view` alone read
# description-only and looked complete. On 2026-08-13 FXA-14325 was skipped for
# two "unanswered" questions that the reporter had answered in a comment before
# tagging the ticket. Always ground with this, never with `view` alone.
jira_ticket() {
  local key="${1:-}"; [ -n "$key" ] || { echo "ERROR: ticket needs <KEY>" >&2; return 1; }
  echo "=== $key description ==="
  acli jira workitem view "$key" 2>/dev/null
  echo
  echo "=== $key comments (oldest first) ==="
  acli jira workitem comment list --key "$key" --json 2>/dev/null \
    | jq -r '.comments[]? | "--- \(.author) [\(.id)]\n\(.body)\n"' \
    || echo "(none)"
}

# jira_reporter_login <KEY>
#   Print the GitHub login of whoever filed the ticket, or nothing if it cannot
#   be resolved. Never guesses: an unmapped reporter prints nothing and the
#   caller assigns the team only. Mapping lives in reporters.tsv in the state
#   directory.
#
#   Match on displayName: Jira's reporter name and GitHub's user.name are both
#   the person's real name. Email was the wrong key, because the local-part does
#   not predict the handle.
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
#   WRITE: put the ticket in the sprint. acli cannot write the Sprint field at
#   all -- it rejects customfield_* in --from-json -- so this is the one call in
#   the tool that talks to the REST API directly, and the only one that needs a
#   Jira API token. Without PIPE_JIRA_BASIC it warns and returns 0, because an
#   unsprinted ticket is a smaller problem than a merge close that aborts.
jira_sprint_add() {
  pipeline_require || return 1
  local key="${1:-}" sid="${2:-}"
  [ -n "$key" ] && [ -n "$sid" ] || return 0
  if [ -z "${PIPE_JIRA_BASIC:-}" ]; then
    echo "WARN: PIPE_JIRA_BASIC unset; $key not added to sprint $sid" >&2
    return 0
  fi
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' -u "$PIPE_JIRA_BASIC" \
            -X POST -H 'Content-Type: application/json' \
            --data "$(jq -nc --arg k "$key" '{issues: [$k]}')" \
            "${PIPE_JIRA_SITE}/rest/agile/1.0/sprint/${sid}/issue" 2>/dev/null)" || code="000"
  [ "$code" = "204" ] || echo "WARN: sprint add for $key returned HTTP $code" >&2
}

# jira_close_merged <KEY>
#   WRITE: finish a merged ticket the way a person would. Assign the reviewer who
#   approved, add it to the active sprint, transition it to Done.
#
#   Nothing used to do this. `merged` wrote the label and the drain comment and
#   stopped, so the ticket kept whatever status and assignee it had before the
#   pipeline touched it. On 2026-09-15 that was 18 merged tickets sitting
#   unassigned at In Review, the oldest merged from a 2020 filing.
#
#   Assignee and sprint are set ONLY when empty. A ticket someone already owns,
#   or already planned into a sprint, is a human's decision and this must not
#   overwrite it. The transition is unconditional: the PR landed.
#
#   Every step warns and continues on failure. A merged ticket with no assignee
#   is still a merged ticket, and failing the label write would leave the state
#   machine worse off than the cosmetic gap it was trying to fix.
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
}

# jira_comment <KEY> <BODY>
#   WRITE: post one comment. Callers lead the body with 🤖 so readers know a
#   pipeline wrote it.
jira_comment() {
  pipeline_require || return 1
  local key="${1:-}" body="${2:-}"
  [ -n "$key" ] && [ -n "$body" ] || { echo "ERROR: comment needs <KEY> <body>" >&2; return 1; }
  acli jira workitem comment create --key "$key" --body "$body" >/dev/null
}
