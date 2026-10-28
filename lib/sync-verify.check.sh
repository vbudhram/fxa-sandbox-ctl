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
# Spanner and Postgres crate changes on a runner whose Spanner stage failed: each is SKIP with
# the reason, never a PASS with no tests, and the run passes. No MySQL row runs a Spanner crate.
mkdir -p "$tmp/w/syncstorage-spanner" "$tmp/w/syncstorage-postgres" "$tmp/run"
printf 'name = "syncstorage-spanner"\n' > "$tmp/w/syncstorage-spanner/Cargo.toml"
printf 'name = "syncstorage-postgres"\n' > "$tmp/w/syncstorage-postgres/Cargo.toml"
echo "no egress" > "$tmp/run/spanner-failed"
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/cargo"
printf '#!/bin/sh\nshift; case "$*" in *spanner.sh*) ;; *restart.sh*|*pytest*|*.py*) exit 0 ;; esac; exec "$@"\n' > "$tmp/bin/timeout"
PATH="$tmp/bin:$PATH" SYNC_WORKSPACE="$tmp/w" SYNC_PROFILE_RUN="$tmp/run" HOME="$tmp" bash "$v" --run --no-firefox > "$tmp/out" 2>&1; rc=$?
vd="$tmp/w/.fxa-verify-verdict.txt"
check "Spanner and Postgres rows are SKIP with the reason, and the run passes" "0|1|1|0|1|1" \
  "$rc|$(grep -c '^SKIP *integration tests (spanner, offload)' "$vd")|$(grep -c '^SKIP *test syncstorage-postgres' "$vd")|$(grep -c '^PASS *test syncstorage-spanner' "$vd")|$(grep -c 'CI must run those Spanner suites' "$vd")|$(grep -q 'no Spanner stack: no egress' "$tmp/out" && echo 1)"
# The plan (no --run) for a diff: which rows it picks.
plan() { (cd "$tmp/p" && git add -A > /dev/null && PATH="$tmp/bin:$PATH" SYNC_WORKSPACE="$tmp/p" HOME="$tmp" bash "$v" 2>/dev/null); }
mkdir -p "$tmp/p"; git -C "$tmp/p" init -q; touch "$tmp/p/Cargo.toml"
for c in syncstorage-db syncstorage-mysql; do mkdir -p "$tmp/p/$c/src"; printf 'name = "%s"\n' "$c" > "$tmp/p/$c/Cargo.toml"; done
mkdir -p "$tmp/p/tools/integration_tests"; git -C "$tmp/p" add -A; git -C "$tmp/p" -c user.name=t -c user.email=t@example.com commit -q -m x
git -C "$tmp/p" update-ref refs/remotes/origin/main HEAD
echo x > "$tmp/p/syncstorage-mysql/src/batch_commit.sql"
check "a MySQL .sql change runs the shared crate's tests, and its Spanner ones" "1|1" \
  "$(plan | grep -c $'test syncstorage-db\t')|$(plan | grep -c "unit tests (spanner).*'package(syncstorage-db)'")"
check "the Postgres clippy row has CI's features (no tokenserver-db/postgres)" "1|0" \
  "$(plan | grep -c '^  clippy postgres')|$(plan | grep -c 'tokenserver-db/postgres')"
git -C "$tmp/p" checkout -q -- . 2>/dev/null; rm -f "$tmp/p/syncstorage-mysql/src/batch_commit.sql"; echo x > "$tmp/p/tools/integration_tests/test_x.py"
check "a change only in the e2e tests runs both e2e rows" "1|1" \
  "$(plan | grep -c $'^  integration tests\t')|$(plan | grep -c 'integration tests (spanner, offload)')"
# spanner.sh unit under 4 GB free: SKIP (exit 3) before it starts anything or builds.
s="$(dirname "$v")/spanner.sh"; mkdir -p "$tmp/sb"
printf '#!/bin/sh\necho "Filesystem 1024-blocks Used Available Capacity Mounted"\necho "/dev/root 61000000 59000000 2000000 97%% /"\n' > "$tmp/sb/df"
printf '#!/bin/sh\necho "$*" >> "%s/cargo.calls"\n' "$tmp" > "$tmp/sb/cargo"; chmod +x "$tmp/sb/"*
PATH="$tmp/sb:$PATH" HOME="$tmp" SYNC_REPO="$tmp/p" SYNC_SPANNER_FEATURES=x SYNC_MYSQL_FEATURES=y bash "$s" unit 'package(a)' > "$tmp/sout" 2>&1; rc=$?
check "the Spanner unit row is SKIP under 4 GB free, and builds nothing" "3|0|1" \
  "$rc|$( [ -f "$tmp/cargo.calls" ] && echo 1 || echo 0)|$(grep -c 'GB free on the runner disk' "$tmp/sout")"
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
