#!/usr/bin/env bash
# Offline check of templates/fxa-mem (search, show, traps, rate and the use log), against a fixture memory folder.
#   bash lib/fxa-mem.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT
fm() { FXA_MEM_DIR="${FXA_MEM_DIR:-$tmp/mem}" FXA_MEM_USE="${FXA_MEM_USE:-$tmp/use.jsonl}" FXA_MEM_OUT="$tmp/out.json" python3 -I "$here/../templates/fxa-mem" "$@"; }

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
  _entry mem-0000000d "kind: command | path: packages/dd/** | cite: packages/dd/package.json:1 | anchor: jest | terms: EREFUSED dns | confirmed: 2026-10-16 | source: run K3 | taint: 0 | digest: 1" \
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
t="$tmp/mem/teams/fxa"; mkdir -p "$t"
_entry mem-000000f1 "kind: system | path:  | cite: mozilla/fxa:a.js:1 | anchor: authApi | cite2: mozilla/other:b.py:2 | anchor2: call_auth_api | confirmed: 2026-10-16 | source: run K8 | taint: 0" \
  "An auth API change needs a crossrepoword client update." "Both sides break." > "$t/system.md"
{
  _entry mem-000000f2 "kind: trap | path:  | cite: mozilla/third:c.go:1 | anchor: pinned | cite2: mozilla/other:b.py:2 | anchor2: call_auth_api | confirmed: 2026-10-16 | source: run K9 | taint: 0" \
    "The other client pins the auth version." "A bump breaks it."
  _entry mem-000000f3 "kind: trap | path: packages/nomatch/** | cite: mozilla/other:b.py:2 | anchor: call_auth_api | confirmed: 2026-10-16 | source: run K9 | taint: 0" \
    "A team trap on a path that does not match." "No match."
} > "$t/trap.md"

check "an error text finds its trap first" "mem-0000000a" "$(fm search "Cannot find module @fxa/shared/foo" | head -1 | cut -d' ' -f1)"
check "a hit line is id, kind, 100-char snippet, repo and topic file, and the confirmed date" "1" "$(fm search foo | head -1 | grep -cE '^mem-[0-9a-f]{8} \[trap\] .{1,100} -> mozilla__fxa/trap\.md \(confirmed 2026-10-16\)$')"
check "one search covers every repo of the team" "mem-0000000e" "$(fm search otherrepoword | head -1 | cut -d' ' -f1)"
check "a search finds the anchor text" "mem-0000000b" "$(fm search uniqanchorword | head -1 | cut -d' ' -f1)"
check "traps --repo keeps out another repo's entry on the same path" "mem-0000000a|0" "$(fm traps --repo mozilla/fxa packages/fxa-content-server/x.js | cut -d' ' -f1)|$(fm traps --repo mozilla/fxa packages/fxa-content-server/x.js | grep -c mem-0000000e)"
check "at most 5 hits" "5" "$(fm search the module test run file | wc -l | tr -d ' ')"
check "FTS syntax in a query searches the words" "0|mem-0000000a" "$(fm search '"foo": NEAR(* -x)' >/dev/null 2>&1; echo $?)|$(fm search '"foo": NEAR(* -x)' | head -1 | cut -d' ' -f1)"
check "no match prints one line and exits 0" "no match|0" "$(o="$(fm search zzzqqq)"; echo "$o|$?")"
check "traps matches the path glob" "mem-0000000a" "$(fm traps --repo mozilla/fxa packages/fxa-content-server/server/lib/x.js | cut -d' ' -f1)"
check "a block with no meta line is skipped, the rest match" "0" "$(fm search nometa | grep -c mem-0000000c)"
check "a stemmed query matches" "mem-0000000b" "$(fm search ports | head -1 | cut -d' ' -f1)"
mkdir -p "$tmp/gitfxa" "$tmp/gitnone" "$tmp/nogit"
git -C "$tmp/gitfxa" init -q && git -C "$tmp/gitfxa" remote add origin git@github.com:mozilla/fxa.git
git -C "$tmp/gitnone" init -q && git -C "$tmp/gitnone" remote add origin https://github.com/mozilla/nofolder.git
check "traps without --repo uses the origin repo" "mem-0000000a" "$(cd "$tmp/gitfxa" && fm traps packages/fxa-content-server/x.js | cut -d' ' -f1)"
check "traps matches the folder itself and a ./ path" "mem-0000000a|mem-0000000a" "$(fm traps --repo mozilla/fxa packages/fxa-content-server | cut -d' ' -f1)|$(fm traps --repo mozilla/fxa ./packages/fxa-content-server/x.js | cut -d' ' -f1)"
check "traps takes an absolute path inside the git tree" "mem-0000000a" "$(cd "$tmp/gitfxa" && fm traps "$tmp/gitfxa/packages/fxa-content-server/x.js" | cut -d' ' -f1)"
check "traps without --repo and without git uses all repos" "mem-0000000a mem-0000000e" "$(cd "$tmp/nogit" && fm traps packages/fxa-content-server/x.js | cut -d' ' -f1 | tr '\n' ' ' | sed 's/ $//')"
check "traps with an origin that has no folder uses all repos" "mem-0000000a mem-0000000e" "$(cd "$tmp/gitnone" && fm traps packages/fxa-content-server/x.js | cut -d' ' -f1 | tr '\n' ' ' | sed 's/ $//')"
check "show prints the cite and the why" "1|1" "$(fm show mem-0000000a | grep -c '^cite: ')|$(fm show mem-0000000a | grep -c '^Why: ')"
touch "$tmp/use.jsonl"
check "an unknown id exits 1 and logs nothing" "1|0" "$(fm show mem-ffffffff >/dev/null 2>&1; echo $?)|$(grep -c ffffffff "$tmp/use.jsonl" || true)"
check "rate logs the rating and its reason" "stale|fixed upstream" "$(fm rate mem-0000000a stale fixed upstream >/dev/null; tail -1 "$tmp/use.jsonl" | jq -r '.rating + "|" + .why')"
check "a bad rating exits 2" "2" "$(fm rate mem-0000000a great >/dev/null 2>&1; echo $?)"
check "each search is logged with its hit ids" "search|true" "$(fm search foo >/dev/null; tail -1 "$tmp/use.jsonl" | jq -r '.cmd + "|" + (.ids | length > 0 | tostring)')"
check "no writable use log still prints hits" "mem-0000000a" "$(FXA_MEM_USE=/nonexistent/x.jsonl fm search foo | head -1 | cut -d' ' -f1)"
check "a missing memory folder prints one line, exit 0" "no team memory on this runner|0" "$(o="$(FXA_MEM_DIR=$tmp/none fm search foo)"; echo "$o|$?")"
check "this host's python has FTS5 (the runner is checked live in Task 7)" "ok" "$(python3 -I -c 'import sqlite3; sqlite3.connect(":memory:").execute("create virtual table t using fts5(x)"); print("ok")')"
check "propose writes a learning the controller accepts" "trap|EREFUSED dns" \
  "$(fm propose --repo mozilla/fxa --kind trap --text t --cite a.js:1 --anchor abcd --why w --path 'packages/**' --terms 'EREFUSED dns' >/dev/null && jq -r '.learnings[0].kind + "|" + .learnings[0].terms' "$tmp/out.json")"
check "propose without terms exits 2" "2" "$(fm propose --repo mozilla/fxa --kind trap --text t --cite a.js:1 --anchor abcd --why w >/dev/null 2>&1; echo $?)"
check "propose with a bad kind exits 2" "2" "$(fm propose --repo mozilla/fxa --kind nope --text t --cite a.js:1 --anchor abcd --why w --terms x >/dev/null 2>&1; echo $?)"
check "propose update needs a good id, and an id needs an op" "2|2|0" "$(fm propose --repo r/r --kind trap --text t --cite a:1 --anchor abcd --why w --terms x --op update >/dev/null 2>&1; echo $?)|$(fm propose --repo r/r --kind trap --text t --cite a:1 --anchor abcd --why w --terms x --id mem-0000000a >/dev/null 2>&1; echo $?)|$(fm propose --repo r/r --kind trap --text t --cite a:1 --anchor abcd --why w --terms x --op supersede --id mem-0000000a >/dev/null 2>&1; echo $?)"
check "propose update with a bad id exits 2" "2" "$(fm propose --repo r/r --kind trap --text t --cite a:1 --anchor abcd --why w --terms x --op update --id nope >/dev/null 2>&1; echo $?)"
rm -f "$tmp/out.json"; fm propose --repo r/r --kind trap --text t --cite a:1 --anchor abcd --why w --terms x --op supersede --id mem-0000000a >/dev/null
check "propose keeps op and id" "supersede|mem-0000000a" "$(jq -r '.learnings[-1].op + "|" + .learnings[-1].id' "$tmp/out.json")"
check "confirm adds an id once" "1" "$(fm confirm mem-0000000a >/dev/null; fm confirm mem-0000000a >/dev/null; jq '.confirmed | length' "$tmp/out.json")"
check "confirm with a bad id exits 2" "2" "$(fm confirm nope >/dev/null 2>&1; echo $?)"
check "the output file is not overwritten when it is not JSON" "1|not json" "$(echo 'not json' > "$tmp/out.json"; fm confirm mem-0000000a >/dev/null 2>&1; echo $?)|$(cat "$tmp/out.json")"
echo '{"learnings": 5}' > "$tmp/out.json"
check "a learnings value that is not a list exits 1, with no traceback" "1|0" "$(o="$(fm confirm mem-0000000a 2>&1)"; echo $?)|$(fm confirm mem-0000000a 2>&1 | grep -c Traceback || true)"
check "KINDS matches _MEMORY_KINDS in lib/memory.sh" "$(sed -n "s/^_MEMORY_KINDS='\(.*\)'.*/\1/p" "$here/memory.sh")" "$(sed -n 's/^KINDS = (\(.*\)).*/\1/p' "$here/../templates/fxa-mem" | tr -d '"' | tr ',' ' ' | tr -s ' ' | sed 's/^ //; s/ $//')"
check "propose and confirm leave the use log alone" "0" "$(rm -f "$tmp/out.json"; : > "$tmp/use.jsonl"; fm confirm mem-0000000a >/dev/null; wc -l < "$tmp/use.jsonl" | tr -d ' ')"
check "terms are searched" "mem-0000000d" "$(fm search EREFUSED | head -1 | cut -d' ' -f1)"
mtk="$(sed -n "s/^_MEMORY_TEAM_KINDS='\(.*\)'.*/\1/p" "$here/memory.sh")"
check "TEAM_KINDS matches _MEMORY_TEAM_KINDS in lib/memory.sh, and has system" "system|$mtk" \
  "$(grep -o system <<< "$mtk")|$(sed -n 's/^TEAM_KINDS = (\(.*\)).*/\1/p' "$here/../templates/fxa-mem" | tr -d '"' | tr ',' ' ' | tr -s ' ' | sed 's/^ //; s/ $//')"
check "search covers team facts and names them" "1" "$(fm search crossrepoword | head -1 | grep -c '^mem-000000f1 .* -> team/system\.md (confirmed 2026-10-16)$')"
check "show prints every cite of a team fact" "1" "$(fm show mem-000000f1 | grep -c '^cite2: mozilla/other:b.py:2$')"
check "traps --repo adds team traps that cite that repo, after its own" "mem-0000000e mem-000000f2" "$(fm traps --repo mozilla/other packages/fxa-content-server/x.js | cut -d' ' -f1 | tr '\n' ' ' | sed 's/ $//')"
nt="$tmp/memteam/teams/fxa"; mkdir -p "$nt"
{ _entry mem-000000a1 "kind: trap | path:  | cite: mozilla/new:n.js:1 | anchor: newanchor | confirmed: 2026-10-16 | source: run K10 | taint: 0" "A trap of the new repo." "w"
  _entry mem-000000a2 "kind: trap | path:  | cite: mozilla/other:b.py:2 | anchor: call_auth_api | confirmed: 2026-10-16 | source: run K10 | taint: 0" "A trap of the other repo." "w"
} > "$nt/trap.md"
check "traps --repo filters team traps by cite when the repo has no folder" "mem-000000a1" "$(FXA_MEM_DIR="$tmp/memteam" fm traps --repo mozilla/new x/y.js | cut -d' ' -f1 | tr '\n' ' ' | sed 's/ $//')"
rm -f "$tmp/out.json"
check "propose --team writes cites with their anchors" "2|mozilla/other:b.py:2|team" \
  "$(fm propose --team --kind system --text t --why w --terms x --cite mozilla/fxa:a.js:1 --anchor aaaa --cite mozilla/other:b.py:2 --anchor bbbb && jq -r '.learnings[-1] | (.cites | length, .[1].cite), .repo' "$tmp/out.json" | paste -sd'|' -)"
check "propose --team with a cite and no anchor exits 2" "2" "$(fm propose --team --kind system --text t --why w --terms x --cite mozilla/fxa:a.js:1 >/dev/null 2>&1; echo $?)"
check "propose --team with a cite and no repo exits 2" "2" "$(fm propose --team --kind system --text t --why w --terms x --cite a.js:1 --anchor aaaa >/dev/null 2>&1; echo $?)"
check "propose --team with 4 cites exits 2" "2" "$(fm propose --team --kind system --text t --why w --terms x $(for i in 1 2 3 4; do printf -- '--cite o/r%s:a.js:1 --anchor aaaa ' "$i"; done) >/dev/null 2>&1; echo $?)"
check "system is refused for a repo fact" "2" "$(fm propose --repo mozilla/fxa --kind system --text t --cite a.js:1 --anchor abcd --why w --terms x >/dev/null 2>&1; echo $?)"
# An entry not confirmed in 90 days comes after a newer one that matches the same, even when it ranks higher.
rk="$tmp/memrank/repos/mozilla__fxa"; mkdir -p "$rk"; today="$(date -u +%F)"; old="$(date -u -v-100d +%F 2>/dev/null || date -u -d '100 days ago' +%F)"
{ _entry mem-000000b1 "kind: trap | path: packages/rank/** | cite: a:1 | anchor: abcd | confirmed: $old | source: r | taint: 0" "rankword rankword rankword old note." "w"
  _entry mem-000000b2 "kind: trap | path: packages/rank/** | cite: a:1 | anchor: abcd | confirmed: $today | source: r | taint: 0" "rankword new note with more words in it." "w"
} > "$rk/trap.md"
check "search and traps put an entry older than 90 days after a newer one" "mem-000000b2 mem-000000b1|mem-000000b2 mem-000000b1" \
  "$(FXA_MEM_DIR="$tmp/memrank" fm search rankword | cut -d' ' -f1 | paste -sd' ' -)|$(FXA_MEM_DIR="$tmp/memrank" fm traps --repo mozilla/fxa packages/rank/x.js | cut -d' ' -f1 | paste -sd' ' -)"
exit "$fail"
