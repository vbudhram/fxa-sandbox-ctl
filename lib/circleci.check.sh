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
curl() ( # a subshell, so its exec > stays inside it
  local url="${*: -1}" out="" a prev=""; echo "$url" >> "$tmp/calls"
  for a in "$@"; do [ "$prev" = -o ] && out="$a"; prev="$a"; done
  [ -n "$out" ] && exec > "$out"
  case "$url" in
    */api/v2/project/gh/mozilla/fxa/711803/artifacts) echo '{"items":[
      {"path":"artifacts/functional/cs-shows-location-local/error-context.md","url":"https://art.example/ec"},
      {"path":"artifacts/functional/cs-shows-location-local/trace.zip","url":"https://art.example/tz"},
      {"path":"artifacts/functional/cs-shows-location-local-retry1/error-context.md","url":"https://art.example/ec-retry"},
      {"path":"artifacts/functional/..%2Fescape/error-context.md","url":"https://art.example/bad"}]}' ;;
    https://art.example/ec) echo '# Error details: element(s) not found service-location' ;;
    https://art.example/tz) echo 'PK-trace' ;;
    */api/v2/project/gh/mozilla/fxa/job/711803) echo '{"name":"playwright-functional-tests","status":"failed"}' ;;
    */api/v2/project/gh/mozilla/fxa/711803/tests) echo '{"items":[{"result":"success","classname":"a","name":"ok"},{"result":"failure","classname":"settings/connectedServices.spec.ts","name":"shows the location","message":"Timeout 10000ms exceeded"}]}' ;;
    */api/v1.1/project/github/mozilla/fxa/711803) echo '{"steps":[{"name":"checkout","actions":[{"failed":null}]},{"name":"run playwright tests","actions":[{"failed":true,"output_url":"https://logs.example/out"}]}]}' ;;
    https://logs.example/out) printf '[{"message":"line one\\n\\u001b[31m1 failed\\u001b[0m\\nkey -----BEGIN RSA PRIVATE KEY-----\\nMIIEfake\\n-----END RSA PRIVATE KEY----- AKIAABCDEFGHIJKLMNOP sha256:%s\\n"}]' "$(printf 'ab%.0s' $(seq 32))" ;;
    */api/v2/workflow/48a37f1d-c27d-4de2-af96-3b954c8b4be3/job) echo '{"items":[{"status":"success","job_number":1,"project_slug":"gh/mozilla/fxa"},{"status":"failed","job_number":711803,"project_slug":"gh/mozilla/fxa"}]}' ;;
    # The newer link form, from a team's own repo, and a failed job of a project that is not the team's.
    */api/v2/workflow/260009ee-1381-456b-9f7a-bc3140b27c3f/job) echo '{"items":[{"status":"failed","job_number":13660,"project_slug":"gh/mozilla/fxa-private","id":"2bceb29d-6a36-4d3b-8b35-f71f5ab6e850"},
      {"status":"failed","job_number":77,"project_slug":"gh/evil/repo","id":"11111111-1111-1111-1111-111111111111"}]}' ;;
    */api/v2/project/gh/mozilla/fxa-private/job/13660) echo '{"name":"Lint (PR)","status":"failed"}' ;;
    */api/v1.1/project/github/mozilla/fxa-private/13660) echo '{"steps":[{"name":"Linting","actions":[{"failed":true,"output_url":"https://logs.example/lint"}]}]}' ;;
    https://logs.example/lint) echo '[{"message":"1069:11  error  Duplicate key no-dupe-keys\nFailed tasks:\n- fxa-auth-server:lint\n"}]' ;;
    *) return 22 ;;
  esac
)

job='see <https://app.circleci.com/pipelines/github/mozilla/fxa/73659/workflows/48a37f1d-c27d-4de2-af96-3b954c8b4be3/jobs/711803|job>'
check "no token: nothing, and no call" "|0" "$(circleci_digests "$job" n1)|$(wc -l < "$tmp/calls" | tr -d ' ')"
mkdir -p "$tmp/.circleci"; printf 'token: "ci-secret"\n' > "$tmp/.circleci/cli.yml"
check "the token comes from the CLI config" "ci-secret" "$(circleci_token)"
out="$(circleci_digests "$job" n1)"
check "the job, its failed test (not the passing one) and the end of its failed step" "yes yes yes yes" \
  "$(grep -q 'playwright-functional-tests, failed' <<< "$out" && echo yes) $(grep -A1 -x 'Failed tests:' <<< "$out" | grep -q 'connectedServices.spec.ts shows the location: Timeout' && echo yes) $(grep -q '^1 failed$' <<< "$out" && echo yes) $(grep -q ' a ok' <<< "$out" || echo yes)"
check "it is fenced as untrusted" "2" "$(grep -c 'CI-n1>>>' <<< "$out")"
check "a private key and an AWS key are scrubbed, an image digest stays" "0|0|1" \
  "$(grep -c 'MIIEfake' <<< "$out")|$(grep -c 'AKIAABCD' <<< "$out")|$(grep -c '^key \[private key\] \[token\] sha256:abab' <<< "$out")"
check "a PR check's job link is read too" "yes" "$(circleci_digests 'https://circleci.com/gh/mozilla/fxa/711803' n6 | grep -q 'playwright-functional-tests, failed' && echo yes)"
out="$(circleci_digests 'https://app.circleci.com/pipelines/github/mozilla/fxa/73659/workflows/48a37f1d-c27d-4de2-af96-3b954c8b4be3' n2)"
check "the first attempt's error context, not the retry's or a bad name" "1|0|0" \
  "$(grep -c 'element(s) not found service-location' <<< "$out")|$(grep -c 'retry1' <<< "$out")|$(grep -c 'escape' <<< "$out")"
check "no folder: no trace downloaded" "0" "$(grep -c 'art.example/tz' "$tmp/calls")"
out="$(circleci_digests "$job" n5 "$tmp/ci")"
check "with a folder: the trace lands there and the digest says where" "PK-trace|1" \
  "$(cat "$tmp/ci/cs-shows-location-local/trace.zip")|$(grep -c '^Trace: /workspace/.fxa-ci/cs-shows-location-local/trace.zip$' <<< "$out")"
check "a workflow link reads its failed job" "yes" "$(grep -q 'Job 711803' <<< "$out" && echo yes)"
: > "$tmp/calls"
check "another project is not read" "|0" "$(circleci_digests 'https://app.circleci.com/pipelines/github/other/repo/1/workflows/48a37f1d-c27d-4de2-af96-3b954c8b4be3/jobs/5' n3)|$(wc -l < "$tmp/calls" | tr -d ' ')"
check "text with no link: nothing" "" "$(circleci_digests 'why does this fail?' n4)"

# The newer link form: app.circleci.com/workflow/<id>/job/<id>, here a check on a team's private repo.
new='https://app.circleci.com/workflow/260009ee-1381-456b-9f7a-bc3140b27c3f/job/2bceb29d-6a36-4d3b-8b35-f71f5ab6e850'
check "circleci_job_path reads the project and number from the workflow" "mozilla/fxa-private/13660|evil/repo/77" \
  "$(circleci_job_path "$new")|$(circleci_job_path https://app.circleci.com/workflow/260009ee-1381-456b-9f7a-bc3140b27c3f/job/11111111-1111-1111-1111-111111111111)"
check "an unknown job id and a bad link fail, with nothing" "fail|fail" \
  "$(circleci_job_path https://app.circleci.com/workflow/260009ee-1381-456b-9f7a-bc3140b27c3f/job/22222222-2222-2222-2222-222222222222 || echo fail)|$(circleci_job_path https://app.circleci.com/workflow/x/job/y || echo fail)"
out="$(PIPE_REPO_SLUG=mozilla/fxa-private circleci_digests "$new" n7)"
check "the team's repo: the digest reads its own project, and not another project's job" "1|1|1|0" \
  "$(grep -c 'Job 13660: Lint (PR), failed' <<< "$out")|$(grep -c 'Duplicate key no-dupe-keys' <<< "$out")|$(grep -c 'fxa-auth-server:lint' <<< "$out")|$(grep -c 'Job 77' <<< "$out")"
check "another team: the private project is not read" "" "$(PIPE_REPO_SLUG=mozilla/other circleci_digests "$new" n8)"
exit "$fail"
