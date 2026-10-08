#!/usr/bin/env bash
# Offline check of pr_card: CI states, reviewers without bots, and only mozilla/fxa links.
#   bash lib/pr-card.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
pat='/^pr_card() {/,/^}/p'; eval "$(sed -n "$pat" "$(dirname "$0")/github.sh")"
ROLLUP='[]'
gh() { printf '%s' "{\"number\":7,\"title\":\"fix(auth): x FXA-12\",\"url\":\"u\",\"state\":\"OPEN\",\"isDraft\":false,\"author\":{\"login\":\"app/fxa-agent\"},\"reviewDecision\":\"CHANGES_REQUESTED\",
  \"latestReviews\":[{\"author\":{\"login\":\"alice\"},\"state\":\"APPROVED\"},{\"author\":{\"login\":\"bob\"},\"state\":\"CHANGES_REQUESTED\"},{\"author\":{\"login\":\"copilot-pull-request-reviewer\"},\"state\":\"COMMENTED\"}],
  \"statusCheckRollup\":${ROLLUP},\"additions\":1,\"deletions\":2,\"changedFiles\":3,\"updatedAt\":\"t\",\"headRefName\":\"h\",\"body\":\"\"}"; }
got() { pr_card https://github.com/mozilla/fxa/pull/7 | jq -r "$1"; }
check "another repo is null" "null" "$(pr_card https://github.com/evil/fxa/pull/7)"
check "no checks: none; author, reviewers without bots, jira" "none|fxa-agent|alice|bob|FXA-12" "$(got '"\(.ci)|\(.author)|\(.approvers|join(","))|\(.changers|join(","))|\(.jira)"')"
ROLLUP='[{"name":"lint","conclusion":"SUCCESS"},{"name":"unit","conclusion":"FAILURE"},{"context":"e2e","state":"PENDING"}]'
check "a failure wins over running, and is named" "fail|3|1|1|unit" "$(got '"\(.ci)|\(.checks)|\(.failed)|\(.running)|\(.failing|join(","))"')"
ROLLUP='[{"name":"lint","conclusion":"SUCCESS"},{"context":"e2e","state":"PENDING"}]'
check "running until every check ends" "running" "$(got .ci)"
ROLLUP='[{"name":"lint","conclusion":"SUCCESS"},{"name":"docs","conclusion":"SKIPPED"}]'
check "skipped counts as done" "pass" "$(got .ci)"
exit "$fail"
