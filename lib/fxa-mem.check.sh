#!/usr/bin/env bash
# Offline check of templates/fxa-mem (search, show, traps, rate and the use log), against a fixture memory folder.
#   bash lib/fxa-mem.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT
fm() { FXA_MEM_DIR="${FXA_MEM_DIR:-$tmp/mem}" FXA_MEM_USE="${FXA_MEM_USE:-$tmp/use.jsonl}" python3 -I "$here/../templates/fxa-mem" "$@"; }

# _entry <id> <meta> <text> <why>   One block, in the shape of _memory_entry in lib/memory.sh.
_entry() { if [ -n "$2" ]; then printf '## %s\n<!-- %s -->\n%s\n\nWhy: %s\n\n' "$1" "$2" "$3" "$4"; else printf '## %s\n%s\n\nWhy: %s\n\n' "$1" "$3" "$4"; fi; }
d="$tmp/mem/repos/mozilla__fxa"; o="$tmp/mem/repos/mozilla__other"; mkdir -p "$d" "$o"
{
  _entry mem-0000000a "kind: trap | path: packages/fxa-content-server/** | cite: packages/fxa-content-server/a.js:42 | anchor: require foo | confirmed: 2026-10-16 | source: run K1 | taint: 1" \
    "Cannot find module @fxa/shared/foo means the shared libs are not built. Build foo first." "The build output is missing."
  _entry mem-0000000b "kind: trap | path: packages/other/** | cite: packages/other/b.js:7 | anchor: uniqanchorword | confirmed: 2026-10-16 | source: run K2 | taint: 0" \
    "The module test fails when the port is busy." "Another run holds the port."
  _entry mem-0000000c "" "nometa this block has no meta line, so the parser skips it. module test run file" "No meta."
} > "$d/trap.md"
{
  _entry mem-0000000d "kind: command | path: packages/dd/** | cite: packages/dd/package.json:1 | anchor: jest | confirmed: 2026-10-16 | source: run K3 | taint: 0 | digest: 1" \
    "Run the unit test of a file with jest." "It is fast."
  _entry mem-0000000f "kind: command | path: packages/y/** | cite: packages/y/package.json:1 | anchor: mocha | confirmed: 2026-10-16 | source: run K4 | taint: 0" \
    "Run one test file with mocha." "It skips the rest."
} > "$d/command.md"
{
  _entry mem-00000010 "kind: gotcha | path: packages/z/** | cite: packages/z/a.js:1 | anchor: config | confirmed: 2026-10-16 | source: run K5 | taint: 0" \
    "The module reads the config file at start." "A restart is needed."
  _entry mem-00000011 "kind: gotcha | path: packages/w/** | cite: packages/w/a.js:1 | anchor: env | confirmed: 2026-10-16 | source: run K6 | taint: 0" \
    "A test run needs the env file." "The default is empty."
} > "$d/config.md"
_entry mem-0000000e "kind: trap | path: packages/fxa-content-server/** | cite: packages/fxa-content-server/c.js:3 | anchor: otherrepoword | confirmed: 2026-10-16 | source: run K7 | taint: 0" \
  "The otherrepoword trap of the other repo." "Another repo." > "$o/trap.md"
echo "- index only" > "$d/INDEX.md"

check "an error text finds its trap first" "mem-0000000a" "$(fm search "Cannot find module @fxa/shared/foo" | head -1 | cut -d' ' -f1)"
check "a hit line is id, kind, 100-char snippet, repo and topic file" "1" "$(fm search foo | head -1 | grep -cE '^mem-[0-9a-f]{8} \[trap\] .{1,100} -> mozilla__fxa/trap\.md$')"
check "one search covers every repo of the team" "mem-0000000e" "$(fm search otherrepoword | head -1 | cut -d' ' -f1)"
check "a search finds the anchor text" "mem-0000000b" "$(fm search uniqanchorword | head -1 | cut -d' ' -f1)"
check "traps --repo keeps out another repo's entry on the same path" "mem-0000000a|0" "$(fm traps --repo mozilla/fxa packages/fxa-content-server/x.js | cut -d' ' -f1)|$(fm traps --repo mozilla/fxa packages/fxa-content-server/x.js | grep -c mem-0000000e)"
check "at most 5 hits" "5" "$(fm search the module test run file | wc -l | tr -d ' ')"
check "FTS syntax in a query searches the words" "0|mem-0000000a" "$(fm search '"foo": NEAR(* -x)' >/dev/null 2>&1; echo $?)|$(fm search '"foo": NEAR(* -x)' | head -1 | cut -d' ' -f1)"
check "no match prints one line and exits 0" "no match|0" "$(o="$(fm search zzzqqq)"; echo "$o|$?")"
check "traps matches the path glob" "mem-0000000a" "$(fm traps --repo mozilla/fxa packages/fxa-content-server/server/lib/x.js | cut -d' ' -f1)"
check "a block with no meta line is skipped, the rest match" "0" "$(fm search nometa | grep -c mem-0000000c)"
check "show prints the cite and the why" "1|1" "$(fm show mem-0000000a | grep -c '^cite: ')|$(fm show mem-0000000a | grep -c '^Why: ')"
check "an unknown id exits 1 and logs nothing" "1|0" "$(fm show mem-ffffffff >/dev/null 2>&1; echo $?)|$(grep -c ffffffff "$tmp/use.jsonl" || true)"
check "rate logs the rating and its reason" "stale|fixed upstream" "$(fm rate mem-0000000a stale fixed upstream >/dev/null; tail -1 "$tmp/use.jsonl" | jq -r '.rating + "|" + .why')"
check "a bad rating exits 2" "2" "$(fm rate mem-0000000a great >/dev/null 2>&1; echo $?)"
check "each search is logged with its hit ids" "search|true" "$(fm search foo >/dev/null; tail -1 "$tmp/use.jsonl" | jq -r '.cmd + "|" + (.ids | length > 0 | tostring)')"
check "no writable use log still prints hits" "mem-0000000a" "$(FXA_MEM_USE=/nonexistent/x.jsonl fm search foo | head -1 | cut -d' ' -f1)"
check "a missing memory folder prints one line, exit 0" "no team memory on this runner|0" "$(o="$(FXA_MEM_DIR=$tmp/none fm search foo)"; echo "$o|$?")"
check "this python has FTS5" "ok" "$(python3 -I -c 'import sqlite3; sqlite3.connect(":memory:").execute("create virtual table t using fts5(x)"); print("ok")')"
exit "$fail"
