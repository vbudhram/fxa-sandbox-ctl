#!/usr/bin/env bash
# Offline check for the perf skill: the throttled server sends whole files at the profile's
# pace and fills the config; measure skips a build whose results are kept; report takes medians.
#   bash skills/fxa-perf/perf.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'kill $srv 2>/dev/null; wait $srv 2>/dev/null; rm -rf "$tmp"' EXIT
command -v node >/dev/null || { echo "skip: needs node"; exit 0; }

mkdir -p "$tmp/builds/a/static/js" "$tmp/builds/b"
printf '<meta name="fxa-config" content="__SERVER_CONFIG__">' > "$tmp/builds/a/index.html"
head -c 300000 /dev/urandom > "$tmp/builds/a/static/js/main.js"
printf '<meta name="fxa-config" content="CFG42"><div data-flow-id="F1"></div>' > "$tmp/live.html"
ln -s "$tmp/builds/a" "$tmp/current"
node "$here/serve.js" "$tmp" mobile 18995 > "$tmp/serve.log" 2>&1 & srv=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do curl -sf -o /dev/null localhost:18995/ 2>/dev/null && break; sleep 0.3; done

t0=$(date +%s); n="$(curl -s localhost:18995/static/js/main.js | wc -c | tr -d ' ')"; secs=$(( $(date +%s) - t0 ))
check "a file arrives whole" "300000" "$n"
# 300 KB at 1.6 Mbit/s is 1.5 s.
check "at the mobile pace" "yes" "$([ "$secs" -ge 1 ] && [ "$secs" -le 4 ] && echo yes || echo "no (${secs}s)")"
check "the page gets the live config" "yes" "$(curl -s localhost:18995/ | grep -q 'content="CFG42"' && echo yes)"
check "an app route gets the page" "yes" "$(curl -s localhost:18995/settings/avatar | grep -q CFG42 && echo yes)"
check "no path out of the build" "yes" "$(curl -s --path-as-is 'localhost:18995/../live.html' | grep -q 'data-flow-id' && echo no || echo yes)"

# measure: a's results are kept, so only b is loaded, once a round.
export PERF_DIR="$tmp" PERF_KEEP="$tmp/keep" PERF_DRY=1
echo '{"files":{"main.js":"/a.js"}}' > "$tmp/builds/a/asset-manifest.json"
echo '{"files":{"main.js":"/b.js"}}' > "$tmp/builds/b/asset-manifest.json"
mkdir -p "$tmp/keep/results"; ka="$(cat "$tmp/builds/a/asset-manifest.json" "$tmp/builds/a/index.html" | { sha1sum 2>/dev/null || shasum; } | cut -c1-12)"
for ms in 900 1000 1100 1200 1300 1400 1500; do echo "{\"shell\":null,\"fcp\":$((ms - 300)),\"form\":$ms,\"submit\":null,\"next\":null}"; done > "$tmp/keep/results/$ka-mobile-first.jsonl"
out="$(bash "$here/perf.sh" measure a,b 7)"
check "a kept build is not measured again" "0" "$(grep -c '^load a' <<< "$out")"
check "the other is loaded each round" "7" "$(grep -c '^load b first' <<< "$out")"
check "report: medians" "a 7 - 900 1200" "$(grep '^a ' <<< "$out" | awk '{ print $1, $2, $3, $4, $5 }')"
check "no build: a clear refusal" "2" "$(bash "$here/perf.sh" measure a,zz 7 >/dev/null 2>&1; echo $?)"

# build <label> <rev>: a scratch repo whose branch deleted old.ts and added new.ts, and a stub build.
R="$tmp/repo"; mkdir -p "$R/packages/fxa-settings" "$R/packages/fxa-react" "$tmp/stub"
( cd "$R" && git init -q && git config user.email user@example.com && git config user.name t
  echo keep > packages/fxa-settings/keep.ts; echo old > packages/fxa-settings/old.ts; echo r > packages/fxa-react/r.ts
  git add -A && git commit -qm base && git rm -q packages/fxa-settings/old.ts && echo new > packages/fxa-settings/new.ts \
  && git add -A && git commit -qm head )
base="$(git -C "$R" rev-parse HEAD~1)"; real_node="$(command -v node)"
printf '#!/bin/sh\nexit 0\n' > "$tmp/stub/npx"
printf '#!/bin/sh\nif [ "$1" = scripts/build.js ]; then [ -n "$SLOW" ] && sleep 30; mkdir -p "$BUILD_PATH"; ls > "$BUILD_PATH/asset-manifest.json"; echo "${HTML:-a}" > "$BUILD_PATH/index.html"; exit 0; fi\nexec %s "$@"\n' "$real_node" > "$tmp/stub/node"
chmod +x "$tmp/stub/npx" "$tmp/stub/node"
pb() { PATH="$tmp/stub:$PATH" PERF_DIR="$tmp/w" PERF_KEEP="$tmp/keep" PERF_WS="$R" bash "$here/perf.sh" build "$@"; }
pb base "$base" >/dev/null 2>&1
check "a rev build puts HEAD back: the deleted file stays gone, the new one stays" "no|yes|clean" \
  "$([ -e "$R/packages/fxa-settings/old.ts" ] && echo yes || echo no)|$([ -e "$R/packages/fxa-settings/new.ts" ] && echo yes || echo no)|$([ -z "$(git -C "$R" status --porcelain)" ] && echo clean || echo dirty)"
# A tool timeout signals perf.sh and the build under it, and only those.
killtree() { local c; for c in $(pgrep -P "$1"); do killtree "$c"; done; kill -TERM "$1" 2>/dev/null; }
SLOW=1 PATH="$tmp/stub:$PATH" PERF_DIR="$tmp/w" PERF_KEEP="$tmp/keep" PERF_WS="$R" bash "$here/perf.sh" build killed "$base" >/dev/null 2>&1 & pid=$!
sleep 1.5; killtree "$pid"; wait "$pid" 2>/dev/null
check "a killed rev build also puts HEAD back" "no|clean" \
  "$([ -e "$R/packages/fxa-settings/old.ts" ] && echo yes || echo no)|$([ -z "$(git -C "$R" status --porcelain)" ] && echo clean || echo dirty)"
HTML=a pb ka >/dev/null 2>&1; HTML=b pb kb >/dev/null 2>&1
eval "$(sed -n '/^key()/p' "$here/perf.sh")"
ka="$(W="$tmp/w" key ka)"; kb="$(W="$tmp/w" key kb)"
check "a change only to index.html changes the key" "yes" "$([ -n "$ka" ] && [ "$ka" != "$kb" ] && echo yes || echo no)"

exit "$fail"
