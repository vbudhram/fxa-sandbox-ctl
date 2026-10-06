#!/usr/bin/env bash
# prove.sh <check> <file>...   A new check must catch the bug it is for: run it with your
# change (it must pass), then with the named files back at HEAD (it must fail). The files
# are copied aside and always restored; the index is not touched.
# PROVE_BASE=<rev>: compare with that revision instead, for a change already committed.
set -uo pipefail
[ "$#" -ge 2 ] || { echo "usage: prove.sh <check.sh> <changed file>..." >&2; exit 2; }
check="$1"; shift; base="${PROVE_BASE:-HEAD}"
tmp="$(mktemp -d)"
restore() { local f; for f in "$@"; do if [ -e "$tmp/$f" ]; then mkdir -p "$(dirname "$f")"; cp -p "$tmp/$f" "$f"; fi; done; rm -rf "$tmp"; }
trap 'restore "$@"' EXIT INT TERM
# The verdict of one run: FAIL lines or a nonzero exit fail it, as test.sh counts them.
verdict() { local out rc=0; out="$(bash "$check" 2>&1)" || rc=$?; if [ "$rc" = 0 ] && ! grep -q '^FAIL' <<< "$out"; then echo pass; else echo fail; fi; }
with="$(verdict)"
for f in "$@"; do
  mkdir -p "$tmp/$(dirname "$f")"; cp -p "$f" "$tmp/$f" || { echo "prove.sh: cannot read $f" >&2; exit 2; }
  # A file new in this change goes away; a changed one goes back to HEAD.
  if git cat-file -e "$base:$f" 2>/dev/null; then git show "$base:$f" > "$f"; else rm -f "$f"; fi
done
without="$(verdict)"
echo "with the change: $with; without it (files at $base): $without"
if [ "$with" = pass ] && [ "$without" = fail ]; then echo "proved: $check catches the change"; exit 0; fi
[ "$with" = pass ] || echo "the check fails even with the change: fix it first"
[ "$without" = pass ] && echo "the check passes without the change: it does not test it"
exit 1
