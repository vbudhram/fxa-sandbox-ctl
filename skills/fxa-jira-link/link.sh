#!/usr/bin/env bash
# link.sh: a link that opens the Jira create screen for FXA with the fields filled in.
# Nothing is created until the person reviews it and clicks Create.
#   link.sh --type bug|task|story|spike --summary "<one line>" [--description "<text>" | --description-file <f>] [--labels a,b]
set -euo pipefail
JIRA="${FXA_JIRA_URL:-https://mozilla-hub.atlassian.net}"
PID="${FXA_JIRA_PID:-10204}"   # FXA (Mozilla Accounts)
type=task summary="" desc="" labels=""
while [ $# -gt 0 ]; do
  case "$1" in
    --type) type="$2"; shift 2 ;;
    --summary) summary="$2"; shift 2 ;;
    --description) desc="$2"; shift 2 ;;
    --description-file) desc="$(cat "$2")"; shift 2 ;;
    --labels) labels="$2"; shift 2 ;;
    *) echo "link.sh: unknown option $1" >&2; exit 2 ;;
  esac
done
case "$type" in
  bug) it=10020 ;; task) it=10007 ;; story) it=10030 ;; spike) it=10057 ;;
  *) echo "link.sh: --type must be bug, task, story or spike" >&2; exit 2 ;;
esac
[ -n "$summary" ] || { echo "link.sh: --summary is required" >&2; exit 2; }
enc() { jq -rn --arg v "$1" '$v | @uri'; }
# Browsers and Slack keep a link of a few thousand characters; a longer description is cut.
[ "${#desc}" -gt 1800 ] && desc="${desc:0:1800}
(cut; see the Slack thread for the rest)"
url="${JIRA}/secure/CreateIssueDetails!init.jspa?pid=${PID}&issuetype=${it}&summary=$(enc "${summary:0:250}")"
[ -n "$desc" ] && url="${url}&description=$(enc "$desc")"
# Split on commas only: a label with a space is not a Jira label, so it is dropped, not split.
IFS=, read -r -a ls <<< "$labels"
for l in ${ls[@]+"${ls[@]}"}; do [[ "$l" =~ ^[A-Za-z0-9_.-]{1,50}$ ]] && url="${url}&labels=${l}"; done
printf '%s\n' "$url"
