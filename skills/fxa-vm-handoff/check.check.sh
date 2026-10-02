#!/usr/bin/env bash
# Offline check for check.sh: scratch files, formatting, and the handoff file.
#   bash skills/fxa-vm-handoff/check.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
command -v jq >/dev/null || { echo "skip: needs jq"; exit 0; }
tmp="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT
C="$(cd "$(dirname "$0")" && pwd)/check.sh"
g() { git -c init.defaultBranch=main -c core.hooksPath=/dev/null -c user.email=t@example.com -c user.name=t "$@"; }
# A fake prettier: a file holding "ugly" is unformatted; --write fixes it.
mkdir -p "$tmp/bin"; cat > "$tmp/bin/npx" <<'NPX'
#!/usr/bin/env bash
[ "$1" = prettier ] || exit 9; shift
mode="$1"; shift; rc=0
for f in "$@"; do case "$f" in --*) continue ;; esac
  grep -q ugly "$f" 2>/dev/null || continue
  if [ "$mode" = --write ]; then sed -i.bak 's/ugly/pretty/' "$f" && rm -f "$f.bak"; else echo "$f"; rc=1; fi
done; exit $rc
NPX
chmod +x "$tmp/bin/npx"; export PATH="$tmp/bin:$PATH" FXA_WORKSPACE="$tmp/repo"

mkdir -p "$tmp/repo/src" && cd "$tmp/repo" && g init -q && echo a > src/a.ts && g add . && g commit -qm init && g update-ref refs/remotes/origin/main HEAD
g checkout -qb agent-x
handoff() { jq -n --arg t "$1" --arg b "${2:-agent-x}" --argjson m "${3:-[]}" '{issue:"agent-x",branch:$b,pr_title:$t,pr_body:"why",media_paths:$m}' > .fxa-auto-done.json; }

echo b > src/a.ts; handoff 'fix(auth): keep the stored location'
check "a clean change and handoff pass" "handoff check: ok" "$(bash "$C")"
handoff 'Fix the location'; bash "$C" >/dev/null; check "an unscoped title fails" 1 $?
handoff 'fix: keep it'; check "a title with no scope is named" 1 "$(bash "$C" | grep -c "not a scoped conventional")"
handoff 'fix(auth): x' other; check "a wrong branch is named" 1 "$(bash "$C" | grep -c "but the checkout is on 'agent-x'")"
handoff 'fix(auth): x' agent-x '[".fxa-auto-media/gone.png"]'; check "a missing media file is named" 1 "$(bash "$C" | grep -c "gone.png, which does not exist")"
mkdir -p .fxa-auto-media && touch .fxa-auto-media/gone.png; check "an existing media file passes" "handoff check: ok" "$(bash "$C")"
echo '{"issue":"x"}' > .fxa-auto-done.json; check "a handoff missing keys is named" 1 "$(bash "$C" | grep -c "needs string keys")"
rm .fxa-auto-done.json; check "no handoff checks the change only" "handoff check: ok" "$(bash "$C")"

echo ugly > src/a.ts; check "an unformatted file is named" 1 "$(bash "$C" | grep -c "not formatted.*src/a.ts")"
check "--fix formats it and then passes" "formatted: src/a.ts|handoff check: ok" "$(bash "$C" --fix | paste -sd'|' -)"
check "--fix wrote the formatted file" pretty "$(cat src/a.ts)"

printf 'a\n<<<<<<< Updated upstream\nb\n=======\nc\n>>>>>>> Stashed changes\n' > src/a.ts
check "conflict markers are named" 1 "$(bash "$C" | grep -c "conflict markers remain in src/a.ts")"
echo pretty > src/a.ts

mkdir -p tests && echo x > tests/zzShot.spec.ts && echo x > src/shot.tmp.mjs
check "scratch files are named" 2 "$(bash "$C" | grep -c "scratch file")"
bash "$C" --fix >/dev/null; check "--fix deletes untracked scratch files" "no|no" "$([ -e tests/zzShot.spec.ts ] && echo yes || echo no)|$([ -e src/shot.tmp.mjs ] && echo yes || echo no)"
echo x > src/kept.tmp.ts && g add src/kept.tmp.ts && g commit -qm kept
bash "$C" --fix >/dev/null; check "--fix leaves a committed scratch file and reports it" "yes|1" "$([ -e src/kept.tmp.ts ] && echo yes)|$(bash "$C" | grep -c "scratch file in the change: src/kept.tmp.ts")"

g rm -q src/kept.tmp.ts && g commit -qm 'drop kept'
# STE in the PR text: named, exit 3 on style alone, so the host asks once and still ships.
body() { jq -n --arg b "$1" --arg t "${2:-fix(auth): keep the stored location}" '{issue:"agent-x",branch:"agent-x",pr_title:$t,pr_body:$b,media_paths:[]}' > .fxa-auto-done.json; }
body 'We utilize the cache.'; bash "$C" >/dev/null; check "style alone exits 3" 3 $?
check "the word and its replacement are named" 1 "$(bash "$C" | grep -c 'PR text, STE: "utilize": use "use"')"
body 'We utilize the cache.' 'Fix it'; bash "$C" >/dev/null; check "style and a real problem exit 1" 1 $?
mkdir -p .github && printf -- '- [ ] I have added necessary documentation (if appropriate).\n' > .github/PULL_REQUEST_TEMPLATE.md
body $'## Because\n\n- The cache was cold.\n\n- [ ] I have added necessary documentation (if appropriate).\n\n```\nutilize(x) // code\n```\nCall `ensure()` first.'
check "template lines, code and inline code are skipped" "handoff check: ok" "$(bash "$C")"
rm -rf .github .fxa-auto-done.json
S="$(dirname "$C")/ste.sh"
check "ste: an em dash" 1 "$(printf 'Fast \342\200\224 and small.\n' | bash "$S" | grep -c 'em dash')"
check "ste: a 26-word sentence" 1 "$(printf '%s\n' "$(printf 'word %.0s' $(seq 26))end." | bash "$S" | grep -c '27 words, limit 25')"
check "ste: 7 sentences in a paragraph" 1 "$(printf 'A. B. C. D. E. F. G.\n' | bash "$S" | grep -c 'paragraph of 7 sentences')"
check "ste: list items are their own paragraphs" "" "$(printf -- '- A. B. C.\n- D. E. F.\n- G.\n' | bash "$S")"
check "ste: a multi-word phrase" 1 "$(printf 'Run it in order to see.\n' | bash "$S" | grep -c '"in order to": use "to"')"

# The host refuses the same titles in finish.sh, where the runner cannot skip it.
eval "$(grep -m1 "local conv=" "$(dirname "$C")/../../lib/finish.sh" | sed 's/^ *local //')"
for t in 'fix(auth): x' 'feat(settings)!: y' 'chore(deps, ci): z'; do check "host takes: $t" yes "$([[ "$t" =~ $conv ]] && echo yes)"; done
for t in 'fix: x' 'Fix(auth): x' 'fix(auth):x' 'update stuff'; do check "host refuses: $t" no "$([[ "$t" =~ $conv ]] || echo no)"; done

[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
