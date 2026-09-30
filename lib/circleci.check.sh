#!/usr/bin/env bash
# Offline check for the CircleCI digest a session gets for a pasted job link.
#   bash lib/circleci.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
HOME="$tmp"; unset CIRCLECI_TOKEN CIRCLECI_CLI_TOKEN; : > "$tmp/calls"
source "$(dirname "$0")/circleci.sh"

# The API, from fixtures. Every call is logged, so a refused link is seen to make none.
curl() {
  local url="${*: -1}"; echo "$url" >> "$tmp/calls"
  case "$url" in
    */api/v2/project/gh/mozilla/fxa/job/711803) echo '{"name":"playwright-functional-tests","status":"failed"}' ;;
    */api/v2/project/gh/mozilla/fxa/711803/tests) echo '{"items":[{"result":"success","classname":"a","name":"ok"},{"result":"failure","classname":"settings/connectedServices.spec.ts","name":"shows the location","message":"Timeout 10000ms exceeded"}]}' ;;
    */api/v1.1/project/github/mozilla/fxa/711803) echo '{"steps":[{"name":"checkout","actions":[{"failed":null}]},{"name":"run playwright tests","actions":[{"failed":true,"output_url":"https://logs.example/out"}]}]}' ;;
    https://logs.example/out) printf '[{"message":"line one\\n\\u001b[31m1 failed\\u001b[0m\\n"}]' ;;
    */api/v2/workflow/48a37f1d-c27d-4de2-af96-3b954c8b4be3/job) echo '{"items":[{"status":"success","job_number":1},{"status":"failed","job_number":711803}]}' ;;
    *) return 22 ;;
  esac
}

job='see <https://app.circleci.com/pipelines/github/mozilla/fxa/73659/workflows/48a37f1d-c27d-4de2-af96-3b954c8b4be3/jobs/711803|job>'
check "no token: nothing, and no call" "|0" "$(circleci_digests "$job" n1)|$(wc -l < "$tmp/calls" | tr -d ' ')"
mkdir -p "$tmp/.circleci"; printf 'token: "ci-secret"\n' > "$tmp/.circleci/cli.yml"
check "the token comes from the CLI config" "ci-secret" "$(circleci_token)"
out="$(circleci_digests "$job" n1)"
check "the job, its failed test (not the passing one) and the end of its failed step" "yes yes yes yes" \
  "$(grep -q 'playwright-functional-tests, failed' <<< "$out" && echo yes) $(grep -A1 -x 'Failed tests:' <<< "$out" | grep -q 'connectedServices.spec.ts shows the location: Timeout' && echo yes) $(grep -q '^1 failed$' <<< "$out" && echo yes) $(grep -q ' a ok' <<< "$out" || echo yes)"
check "it is fenced as untrusted" "2" "$(grep -c 'CI-n1>>>' <<< "$out")"
out="$(circleci_digests 'https://app.circleci.com/pipelines/github/mozilla/fxa/73659/workflows/48a37f1d-c27d-4de2-af96-3b954c8b4be3' n2)"
check "a workflow link reads its failed job" "yes" "$(grep -q 'Job 711803' <<< "$out" && echo yes)"
: > "$tmp/calls"
check "another project is not read" "|0" "$(circleci_digests 'https://app.circleci.com/pipelines/github/other/repo/1/workflows/48a37f1d-c27d-4de2-af96-3b954c8b4be3/jobs/5' n3)|$(wc -l < "$tmp/calls" | tr -d ' ')"
check "text with no link: nothing" "" "$(circleci_digests 'why does this fail?' n4)"
exit "$fail"
