#!/usr/bin/env bash
# Offline check that sync-verify writes one run line in fxa-verify's shape, so the host counts its runs.
#   bash lib/sync-verify.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
command -v jq >/dev/null || { echo "skip: needs jq"; exit 0; }
tmp="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT
v="$(cd "$(dirname "$0")/.." && pwd)/profiles/sync-storage/skills/sync-verify/verify.sh"
# A repo with no change: build, fmt and clippy only. cargo and timeout are fakes on the PATH.
mkdir -p "$tmp/bin" "$tmp/w"; git -C "$tmp/w" init -q; touch "$tmp/w/Cargo.toml"; git -C "$tmp/w" add Cargo.toml; git -C "$tmp/w" -c user.name=t -c user.email=t@example.com commit -q -m x
git -C "$tmp/w" update-ref refs/remotes/origin/main HEAD
printf '#!/bin/sh\nshift; exec "$@"\n' > "$tmp/bin/timeout"
printf '#!/bin/sh\n[ "$1" = fmt ] && [ -n "${FMT_FAILS:-}" ] && exit 1\nexit 0\n' > "$tmp/bin/cargo"; chmod +x "$tmp/bin/"*
run() { PATH="$tmp/bin:$PATH" SYNC_WORKSPACE="$tmp/w" HOME="$tmp" bash "$v" --run >/dev/null 2>&1; }
run
check "a passing run writes one line: three rows, none failed" "1|full|3|0" "$(wc -l < "$tmp/w/.fxa-verify-runs.jsonl" | tr -d ' ')|$(jq -r '"\(.mode)|\(.rows)|\(.fail)"' "$tmp/w/.fxa-verify-runs.jsonl")"
FMT_FAILS=1 run
check "a failed row counts as a failed run" "2|1" "$(wc -l < "$tmp/w/.fxa-verify-runs.jsonl" | tr -d ' ')|$(tail -1 "$tmp/w/.fxa-verify-runs.jsonl" | jq .fail)"
# A team stack: /workspace holds only links, so the build runs in the repo and the records stay in /workspace.
mkdir -p "$tmp/ws"; printf '#!/bin/sh\n[ -f Cargo.toml ] || exit 101\nexit 0\n' > "$tmp/bin/cargo"
PATH="$tmp/bin:$PATH" SYNC_WORKSPACE="$tmp/ws" SYNC_REPO="$tmp/w" HOME="$tmp" bash "$v" --run >/dev/null 2>&1
check "in a team stack the build runs in the repo and the run line lands in /workspace" "0" "$(jq .fail "$tmp/ws/.fxa-verify-runs.jsonl")"
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
