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
mkdir -p "$tmp/keep/results"; ka="$( { sha1sum 2>/dev/null || shasum; } < "$tmp/builds/a/asset-manifest.json" | cut -c1-12)"
for ms in 900 1000 1100 1200 1300 1400 1500; do echo "{\"shell\":null,\"fcp\":$((ms - 300)),\"form\":$ms,\"submit\":null,\"next\":null}"; done > "$tmp/keep/results/$ka-mobile-first.jsonl"
out="$(bash "$here/perf.sh" measure a,b 7)"
check "a kept build is not measured again" "0" "$(grep -c '^load a' <<< "$out")"
check "the other is loaded each round" "7" "$(grep -c '^load b first' <<< "$out")"
check "report: medians" "a 7 - 900 1200" "$(grep '^a ' <<< "$out" | awk '{ print $1, $2, $3, $4, $5 }')"
check "no build: a clear refusal" "2" "$(bash "$here/perf.sh" measure a,zz 7 >/dev/null 2>&1; echo $?)"

exit "$fail"
