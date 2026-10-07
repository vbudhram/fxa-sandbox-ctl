#!/usr/bin/env bash
# Offline check that personal or internal data never reaches a PR: the scanner, and the guard on a staged change.
#   bash lib/finish-pii.check.sh
set -euo pipefail
fail=0
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/finish-pii.XXXXXX")"; trap 'rm -rf "$tmp"' EXIT
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
# scan <text>   The kinds the scanner finds in a PR body line, or "clean".
scan() { jq -n --arg b "$1" '{pr_body: $b}' > "$tmp/p.json"; : > "$tmp/d"
  python3 "$here/pii_guard.py" "$tmp/p.json" "$tmp/d" | sed 's/^pr_body line 1: //' | paste -sd, - | sed 's/^$/clean/'; }
# scan_diff <added line>   The same for one added line of a diff.
scan_diff() { echo '{}' > "$tmp/p.json"; printf '+++ b/src/a.ts\n@@ -1,0 +7 @@\n+%s\n' "$1" > "$tmp/d"
  python3 "$here/pii_guard.py" "$tmp/p.json" "$tmp/d" | paste -sd, - | sed 's/^$/clean/'; }

check "a user's email" "email" "$(scan 'reported by jane.doe@gmail.com')"
check "fake and Mozilla emails pass" "clean" "$(scan 'user@example.com test@restmail.net support@mozilla.com icon@2x.png')"
check "a public IP" "IP address" "$(scan 'from 81.12.40.7 today')"
check "a private IP is internal" "IP address" "$(scan 'manager at 10.42.2.2')"
check "localhost, docs IPs and versions pass" "clean" "$(scan '127.0.0.1 0.0.0.0 192.0.2.1 release 1.346.7 Firefox 140.0')"
check "a user agent version and docker's host pass" "clean" "$(scan 'Chrome/124.0.0.0 Safari/537.36 http://host.docker.internal:8093')"
check "an IP in a URL" "IP address" "$(scan 'http://81.12.40.7/v1')"
check "an IPv6 address" "IP address" "$(scan 'peer 2a02:1810:4d02:2000::1')"
check "a phone number" "phone number" "$(scan 'texted +447911123456')"
check "a 555 test number passes" "clean" "$(scan 'texted +15555550100')"
check "a Sentry user line" "FxA uid,Sentry user data" "$(scan '**user**: id:a8efed57a80e4a3ddd98d0c035837c86')"
check "a geo header" "Sentry user data" "$(scan '"x-sigsci-client-geo-city": "mashhad"')"
check "a session token" "token" "$(scan 'token 00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff')"
check "SSO-protected links pass" "clean" \
  "$(scan 'https://mozilla.sentry.io/issues/FXA-AUTH-39E https://mozilla.slack.com/archives/C01/p1 https://docs.google.com/d/1')"
check "a GCP project and an internal host" "internal host" "$(scan 'moz-fx-dev-sandbox metadata.google.internal')"
check "a secret" "secret" "$(scan 'GH_TOKEN=ghp_abcdefghijklmnop1234')"
check "a Sentry short id, Jira and GitHub links pass" "clean" \
  "$(scan 'Fixes FXA-AUTH-39E. Closes FXA-123 https://mozilla-hub.atlassian.net/browse/FXA-123 https://github.com/mozilla/fxa/pull/1')"
check "a fixture uid or token in code passes" "clean" \
  "$(scan_diff "const uid = 'a8efed57a80e4a3ddd98d0c035837c86'; const t = '$(printf 'ab%.0s' {1..32})';")"
check "made-up test emails and private IPs in code pass" "clean" "$(scan_diff "send('u@e.com', 'hey@happy.com', '10.0.0.1')")"
check "placeholder IPs, a fake local part, a format note pass" "clean" \
  "$(scan_diff "ip('1.2.3.4', '8.8.8.8'); to('test@aol.com'); // Bearer <prefix>_<hex>")"
check "a real-provider email in a test" "src/a.ts:7: email" "$(scan_diff "to('bloop@gmail.com')")"
check "an asset file is not read" "clean" "$(echo '{}' > "$tmp/p.json"
  printf '+++ b/a/logo.svg\n@@ -0,0 +1 @@\n+<path d="M81.12.40.7"/>\n' > "$tmp/d"
  python3 "$here/pii_guard.py" "$tmp/p.json" "$tmp/d" | sed 's/^$/clean/')"
check "an email in code, with its place" "src/a.ts:7: email" "$(scan_diff "const to = 'jane.doe@gmail.com';")"

# The guard on a staged change, as finish runs it after the squash.
FINISH_LIB_DIR="$here"
eval "$(sed -n '/^_finish_pii_guard() {/,/^}/p' "$here/finish.sh")"
wt="$tmp/wt"; git init -q "$wt"; git -C "$wt" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
echo '{"feedback_summary": ["fixed the test"], "open_questions": []}' > "$tmp/done.json"
printf 'export const x = 1;\n' > "$wt/a.ts"; git -C "$wt" add a.ts
check "a clean change ships" "0" "$(_finish_pii_guard "$wt" "$tmp/done.json" 'fix(auth): x' 'body' 'Closes FXA-1' 2>/dev/null; echo $?)"
check "an IP in the PR body stops it" "1" "$(_finish_pii_guard "$wt" "$tmp/done.json" 'fix(auth): x' 'from 81.12.40.7' '' 2>/dev/null; echo $?)"
check "the error names the place, not the value" "ERROR: refusing to ship: personal or internal data in the PR: pr_body line 1: IP address" \
  "$(_finish_pii_guard "$wt" "$tmp/done.json" 'fix(auth): x' 'from 81.12.40.7' '' 2>&1 >/dev/null | head -1)"
echo '{"feedback_summary": ["user jane.doe@gmail.com saw it"]}' > "$tmp/done2.json"
check "the round summary is checked" "1" "$(_finish_pii_guard "$wt" "$tmp/done2.json" 'fix(auth): x' 'body' '' 2>/dev/null; echo $?)"
printf 'const ip = "81.12.40.7";\n' >> "$wt/a.ts"; git -C "$wt" add a.ts
check "an IP in the diff stops it" "1" "$(_finish_pii_guard "$wt" "$tmp/done.json" 'fix(auth): x' 'body' '' 2>/dev/null; echo $?)"
exit "$fail"
