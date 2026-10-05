#!/usr/bin/env bash
# Offline check of which PR comments reach a feedback round: trust by repo permission,
# review summaries, and outdated comments until their thread is resolved.
#   bash lib/feedback-trust.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
command -v jq >/dev/null || { echo "skip: needs jq"; exit 0; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
source "$(dirname "$0")/github.sh"
pipeline_require() { :; }
worktree_branch_for() { echo fxa-1; }
PIPE_STATE_DIR="$tmp" PIPE_REPO_SLUG="mozilla/fxa"
# A private org member reads as CONTRIBUTOR; an outsider is CONTRIBUTOR too.
gh() {
  case "$*" in
    "pr list"*) echo 7 ;;
    *pulls/7/comments*) echo '[{"id":1,"position":3,"user":{"login":"member-a","type":"User"},"author_association":"CONTRIBUTOR","path":"a.ts","line":3,"body":"fix"},
      {"id":2,"position":4,"user":{"login":"outsider","type":"User"},"author_association":"CONTRIBUTOR","path":"a.ts","line":4,"body":"x"},
      {"id":3,"position":5,"user":{"login":"Copilot","type":"Bot"},"author_association":"CONTRIBUTOR","path":"a.ts","line":5,"body":"c"},
      {"id":4,"position":6,"user":{"login":"member-a","type":"User"},"author_association":"CONTRIBUTOR","path":"a.ts","line":6,"body":"done"},
      {"id":5,"position":null,"user":{"login":"member-a","type":"User"},"author_association":"CONTRIBUTOR","path":"a.ts","line":null,"original_line":8,"body":"moved"}]' ;;
    *graphql*) [ -n "${NO_GRAPHQL:-}" ] && return 1; echo '["4"]' ;;
    *pulls/7/reviews*) echo '[{"id":20,"user":{"login":"member-a","type":"User"},"author_association":"CONTRIBUTOR","state":"CHANGES_REQUESTED","body":"Needs a test"},
      {"id":21,"user":{"login":"copilot-pull-request-reviewer[bot]","type":"Bot"},"author_association":"CONTRIBUTOR","state":"COMMENTED","body":"overview"},
      {"id":22,"user":{"login":"member-a","type":"User"},"author_association":"CONTRIBUTOR","state":"APPROVED","body":""}]' ;;
    *issues/7/comments*) echo '[{"id":9,"user":{"login":"member-a","type":"User"},"author_association":"CONTRIBUTOR","body":"please"}]' ;;
    *collaborators/member-a/permission*) echo admin ;;
    *collaborators/outsider/permission*) echo read ;;
    *) return 1 ;;
  esac
}
got="$(gh_feedback FXA-1 | jq -r '[.comments[] | "\(.id)=\(.trusted)"] | join(" ")')"
check "a member with write access is trusted, inline and in the conversation" "yes" "$(grep -q '1=true' <<<"$got" && grep -q 'i9=true' <<<"$got" && echo yes)"
check "a reader is not trusted" "yes" "$(grep -q '2=false' <<<"$got" && echo yes)"
check "Copilot stays trusted" "yes" "$(grep -q '3=true' <<<"$got" && echo yes)"
check "a resolved thread is left out" "no" "$(grep -q '4=' <<<"$got" && echo yes || echo no)"
fb="$(gh_feedback FXA-1)"
check "an outdated open thread counts, marked outdated, at its original line" "true 8" "$(jq -r '.comments[] | select(.id == "5") | "\(.outdated) \(.line)"' <<<"$fb")"
check "a human review summary counts, with its state" "CHANGES_REQUESTED true" "$(jq -r '.comments[] | select(.id == "r20") | "\(.state) \(.trusted)"' <<<"$fb")"
check "Copilot's overview and an empty approval are left out" "no" "$(jq -e '.comments[] | select(.id == "r21" or .id == "r22")' <<<"$fb" >/dev/null && echo yes || echo no)"
check "without the thread list, outdated comments are left out as before" "no" \
  "$(NO_GRAPHQL=1 gh_feedback FXA-1 | jq -e '.comments[] | select(.id == "5")' >/dev/null && echo yes || echo no)"
exit "$fail"
