#!/usr/bin/env bash
# Offline check of an investigation routine (on jira-label) in lib/routine.py: the config check, the host frame,
# the fxa-investigation parser and the Jira comment renderer with its sanitizer.
#   bash lib/routine-investigate.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
here="$(cd "$(dirname "$0")" && pwd)"
py() { python3 -I "$here/routine.py" "$@"; }
echo '{"schema":1,"teams":{}}' > "$tmp/index.json"; : > "$tmp/bot.env"
pub='{"profile":"fxa","read_only":false,"private":false,"secret":false,"repos":[{"slug":"mozilla/fxa","role":"work"},{"slug":"mozilla/dep","role":"dep"}]}'
val() { printf '%s' "$2" > "$tmp/p.json"; printf '%s' "$1" > "$tmp/r.json"
  py validate "$tmp/r.json" fxa --profile "$tmp/p.json" --index "$tmp/index.json" --bot-env "$tmp/bot.env" 2>&1; }
good='{"name":"Investigate","on":"jira-label","template":"investigate","mode":"report","channel":"C0OWN00","repos":["mozilla/fxa"]}'

check "a jira-label routine passes, with the jira defaults and no schedule" 'ai-investigate|5|10|null' \
  "$(val "$good" "$pub" | jq -r '"\(.jira.label)|\(.jira.sweep_min)|\(.max_usd)|\(.schedule)"')"
check "a secret team, a private team and a team that does not say are refused" "1|1|1" \
  "$(for p in "$(jq -c '.secret = true' <<< "$pub")" "$(jq -c '.private = true' <<< "$pub")" "$(jq -c 'del(.private)' <<< "$pub")"; do
     val "$good" "$p" | grep -c 'public teams only'; done | paste -sd'|' -)"
check "mode, channel, repo and template rules" "1|1|1|1|1" \
  "$(val "$(jq -c '.mode = "pr"' <<< "$good")" "$pub" | grep -c '^mode: An investigation')|$(val "$(jq -c 'del(.channel)' <<< "$good")" "$pub" | grep -c '^channel: A Jira label')|$(val "$(jq -c '.repos = ["mozilla/dep"]' <<< "$good")" "$pub" | grep -c '^repos: An investigation')|$(val "$(jq -c '.template = "blank" | .prompt = "x"' <<< "$good")" "$pub" | grep -c '^template: A Jira label')|$(val "$(jq -c 'del(.on) | .schedule = "daily 07:00" | .zone = "UTC"' <<< "$good")" "$pub" | grep -c '^template: The investigate template needs')"
check "a bad jira block and a jira block on a schedule routine are refused" "1|1|1" \
  "$(val "$(jq -c '.jira = {label: "a b", sweep_min: 0, x: 1}' <<< "$good")" "$pub" | grep -c '^jira: label')|$(val "$(jq -c '.jira = {sweep_min: 0}' <<< "$good")" "$pub" | grep -c '^jira: sweep_min')|$(val '{"name":"R","template":"blank","prompt":"x","schedule":"daily 07:00","zone":"UTC","mode":"report","repos":["mozilla/fxa"],"jira":{}}' "$pub" | grep -c '^jira: Only')"
check "a label without the ai-investigate prefix is refused (Slack drafts can add it); one with it passes" "1|ai-investigate-auth" \
  "$(val "$(jq -c '.jira = {label: "triage-me"}' <<< "$good")" "$pub" | grep -c '^jira: label')|$(val "$(jq -c '.jira = {label: "ai-investigate-auth"}' <<< "$good")" "$pub" | jq -r .jira.label)"
printf '%s' "$(val "$good" "$pub")" > "$tmp/cfg.json"
check "a jira-label routine has no next run and is never due" "|null" "$(py next "$tmp/cfg.json" | paste -sd, -)|$(py due "$tmp/cfg.json" 1790000000)"

# The host frame: the checked key, team and repo; no ticket text.
echo '{"investigate":{"key":"FXA-123","by":"acc-a1"}}' > "$tmp/h.json"
fr="$(py prompt "$tmp/cfg.json" "$tmp/h.json" fxa 0123456789ab)"
check "the frame names the key and repo, says report only, and gives the output rule" "1|1|1|1" \
  "$(grep -c 'investigation of Jira ticket FXA-123 in mozilla/fxa' <<< "$fr")|$(grep -c '^Report only. Change no file' <<< "$fr")|$(grep -c 'fxa-jira-context.md' <<< "$fr")|$(grep -c '```fxa-investigation' <<< "$fr")"
echo '{"investigate":{"key":"FXA-1; rm -rf /","by":"x"}}' > "$tmp/bad.json"
check "a bad key is refused" "1" "$(py prompt "$tmp/cfg.json" "$tmp/bad.json" fxa 0123456789ab >/dev/null 2>&1; echo $?)"

# The parser and the renderer.
cat > "$tmp/report.md" <<'R'
I looked at the code.
```fxa-investigation
{"ask": "Make **login** work [see](https://evil.example/x) again",
 "cause": "The `check` in   www.evil.example/a fails\nhttp://evil.example/b on retry",
 "confidence": "certain",
 "evidence": ["git log shows it", "ftp://x.example/y", 7, "see _https://evil.example/u", "9https://evil.example/n"],
 "since_last": null,
 "fix": {"summary": "Guard the retry", "steps": [
   {"file": "packages/a/b.ts:120-134", "change": "Add a guard"},
   {"file": "packages/gone.ts", "lines": "5", "change": "Remove it"},
   {"file": "../../etc/passwd", "lines": "1", "change": "Read it"}],
   "tests": [{"file": "packages/a/b.spec.ts", "case": "retries once"}, {"file": "nope.spec.ts", "case": "x"}],
   "verify": "yarn test b"},
 "acceptance": ["login works"], "risks": ["none"], "not_checked": ["Sentry", "CI"],
 "related": ["FXA-1", "#343", "https://github.com/a/b/pull/1", "evil", "FXA-1", "bug 1234567", "sentry:4567", "bug 1; x"]}
```
R
printf 'packages/a/b.ts\npackages/a/b.spec.ts\n' > "$tmp/paths"
out="$(py investigate-render "$tmp/report.md" FXA-123 42 mozilla/fxa https://jira.example.net "$tmp/paths")"
c="$(jq -r .comment <<< "$out")"
check "the comment leads with the robot, the key, the run and the confidence (a bad one is low)" "🤖 Investigation of FXA-123 (run 42)  ·  confidence: low" "$(head -1 <<< "$c")"
check "no agent URL, markdown link or inline marker is left" "0|0|0|Ask: Make login work see again" \
  "$(grep -c 'evil' <<< "$c")|$(grep -c 'ftp:' <<< "$c")|$(grep -c '\*\*' <<< "$c")|$(grep '^Ask:' <<< "$c")"
check "a path in the repo keeps its lines; a missing one and an escape are dropped" '1. `packages/a/b.ts:120-134`: Add a guard|2. Remove it|3. Read it' \
  "$(grep -E '^[0-9]\. ' <<< "$c" | paste -sd'|' -)"
check "tests keep only paths in the repo" '- `packages/a/b.spec.ts`: retries once|- x' "$(sed -n '/^Tests:/,/^Verify:/p' <<< "$c" | grep '^- ' | paste -sd'|' -)"
check "related keeps only keys, PR numbers, bugs and Sentry ids, once each, with host links" 'Related: [FXA-1](https://jira.example.net/browse/FXA-1), [#343](https://github.com/mozilla/fxa/pull/343), [bug 1234567](https://bugzilla.mozilla.org/show_bug.cgi?id=1234567), [Sentry 4567](https://mozilla.sentry.io/issues/4567/)' \
  "$(grep '^Related:' <<< "$c")"
check "the notes are the text before the block, with a header" "# Investigation of FXA-123 (run 42)|1|0" \
  "$(jq -r .notes <<< "$out" | head -1)|$(jq -r .notes <<< "$out" | grep -c '^I looked at the code\.$')|$(jq -r .notes <<< "$out" | grep -c 'fxa-investigation')"
check "the result keeps the dropped path as null; the comment ends with the ai-fixme line" "null|To have the bot make this fix, add the ai-fixme label." \
  "$(jq -r '.result.fix.steps[1].file' <<< "$out")|$(tail -1 <<< "$c")"
printf '```fxa-investigation\n{"ask": "%s", "cause": "c"}\n```\n' "$(printf 'a%.0s' $(seq 1 900))" > "$tmp/long.md"
check "a field is capped, and since_last shows only when given" "605|0" \
  "$(py investigate-render "$tmp/long.md" FXA-1 1 mozilla/fxa https://jira.example.net "$tmp/paths" | jq -r .comment | grep '^Ask:' | jq -Rr length)|$(grep -c 'Since the last run' <<< "$c")"
check "a cut field ends with an ellipsis" "…" "$(py investigate-render "$tmp/long.md" FXA-1 1 mozilla/fxa https://jira.example.net "$tmp/paths" | jq -r .comment | grep '^Ask:' | grep -o '…$')"
printf '```fxa-investigation\n{"ask": "a", "cause": "%s. Then more words follow here, long enough to pass the cap of three hundred.", "fix": {"summary": "s"}}\n```\n' "$(printf 'a%.0s' $(seq 1 250))" > "$tmp/sent.md"
check "the short comment cuts the cause at a sentence end" "Cause: $(printf 'a%.0s' $(seq 1 250))." \
  "$(py investigate-render "$tmp/sent.md" FXA-1 1 mozilla/fxa https://jira.example.net "$tmp/paths" | jq -r .short | grep '^Cause:')"
printf 'no block here\n' > "$tmp/none.md"; printf '```fxa-investigation\n[1]\n```\n' > "$tmp/list.md"; printf '```fxa-investigation\n{"ask": "a"}\n```\n' > "$tmp/nocause.md"
check "no block, a block that is not an object, and no cause fail" "1|1|1" \
  "$(for f in none list nocause; do py investigation "$tmp/$f.md" >/dev/null 2>&1; echo $?; done | paste -sd'|' -)"
exit $fail
