#!/usr/bin/env bash
# dashboard/index.html: the Answers tab names each quick answer by its question, with its id beside it.
#   bash skills/fxa-ctl-dev/page-answers.check.sh
set -u
here="$(dirname "$0")" p="$(dirname "$0")/page.sh"; fail=0
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
ck() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; fail=1; fi; }
at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq --arg at "$at" '. + {"/api/stats": {rows: [{src: "answer", key: "ask-aaa111", at: $at, kind: "answered", usd: 0.2, q: "Why does <b>login</b> fail?"}, {src: "answer", key: "ask-bbb222", at: $at, kind: "failed", usd: 0.1}]}}' \
  "$here/page-fixture.json" > "$tmp/fx.json"
out="$(bash "$p" '#sessions/answers' --fixture "$tmp/fx.json" --probe 'await new Promise(r => setTimeout(r, 700));
  const b = [...document.querySelectorAll("button[data-ans-btn]")];
  return [b.length, b.map(x => x.textContent.trim()).sort().join(","), !!document.querySelector("#s-sess b"), /ask-aaa111/.test(b.find(x => x.dataset.ansBtn === "ask-aaa111")?.closest("td").textContent)].join("|")')"; rc=$?
[ "$rc" = 3 ] && { echo "SKIP (no Chrome): the page probes did not run; set CHROME to run them"; exit 0; }
ck "a row shows its question as text with the id beside it; a row with no question shows its id" "2|Why does <b>login</b> fail?,ask-bbb222|false|true" "$out"
exit "$fail"
