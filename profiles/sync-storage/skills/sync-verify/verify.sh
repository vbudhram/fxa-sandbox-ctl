#!/usr/bin/env bash
# sync-verify: prove a syncstorage-rs change. Build, fmt, clippy and the changed crates' tests
# the CI way, then the change seen on the running server: the plan's own checks, the protocol
# check and a real Firefox sync. See SKILL.md.
#   verify.sh [--run] [--plan FILE] [--no-firefox]
set -uo pipefail
SK="$(cd "$(dirname "$0")" && pwd)" W="${SYNC_WORKSPACE:-/workspace}" PY="$HOME/.syncstorage-venv/bin/python"
# In a team stack /workspace only links to each repo: the build and tests run in the repo, the records stay in $W.
R="$W"; [ -f "$W/Cargo.toml" ] || R="${SYNC_REPO:-/home/agent/syncstorage}"
cd "$R" || exit 2
export RUSTUP_HOME=/opt/rust/rustup PATH=/opt/rust/cargo/bin:$PATH
F="--no-default-features --features=syncstorage-db/mysql --features=py_verifier"
# CI's other two backends, in the same target dir: a second dir built the gRPC library and the
# common crates again and filled the runner's disk.
SF="--no-default-features --features=syncserver/spanner --features=py_verifier --features=syncserver/last_seen"
PF="--no-default-features --features=syncstorage-db/postgres --features=py_verifier"
run=0 plan="" ff=1
while [ $# -gt 0 ]; do
  case "$1" in --run) run=1 ;; --plan) plan="${2:-}"; shift ;; --no-firefox) ff=0 ;;
    *) echo "usage: verify.sh [--run] [--plan FILE] [--no-firefox]" >&2; exit 2 ;; esac; shift
done

# The changed files since origin/main, untracked ones too, and the crate of each.
base="$(git merge-base HEAD origin/main 2>/dev/null || echo HEAD)"
changed="$( { git diff --name-only "$base"; git ls-files -o --exclude-standard; } | grep -v '^\.fxa-' | sort -u)"
crates="$(for f in $changed; do d="$(dirname "$f")"
  while [ "$d" != . ] && [ ! -f "$d/Cargo.toml" ]; do d="$(dirname "$d")"; done
  [ "$d" != . ] && sed -n 's/^name *= *"\(.*\)"/\1/p' "$d/Cargo.toml" | head -1; done | sort -u)"
# A backend crate's tests live in the shared crate (syncstorage-db/src/tests), so a change in one runs them.
crates="$( { echo "$crates"; grep -qE '^syncstorage-(mysql|postgres|spanner)$' <<< "$crates" && echo syncstorage-db
  grep -qE '^tokenserver-(mysql|postgres)$' <<< "$crates" && echo tokenserver-db; } | grep . | sort -u)"
# Server code, or the e2e tests and the payload-link tools the e2e rows run.
server=0; grep -qE '^((syncserver|syncstorage|tokenserver)[a-z-]*|tools/(integration_tests|payload-[a-z-]*))/' <<< "$changed" && server=1

rows=()  # "name<TAB>command"
row() { rows+=("$1"$'\t'"$2"); }
row build "cargo build --bin syncserver $F"
row fmt "cargo fmt --all -- --check"
row clippy "cargo clippy --workspace --all-targets $F -- -D clippy::dbg_macro -D warnings"
# CI's clippy job runs for each backend: code behind the spanner or postgres feature compiles only there.
if [ -n "$crates" ]; then
  row "clippy spanner" "cargo clippy --workspace --all-targets $SF -- -D clippy::dbg_macro -D warnings"
  row "clippy postgres" "cargo clippy --workspace --all-targets $PF -- -D clippy::dbg_macro -D warnings"
fi
# CI's python-checks job, on the Python tools.
if grep -q '^tools/.*\.py$' <<< "$changed"; then
  row "ruff format" "$HOME/.syncstorage-venv/bin/ruff format --diff tools"
  row "ruff check" "$HOME/.syncstorage-venv/bin/ruff check tools"
fi
TESTENV="SYNC_SYNCSTORAGE__DATABASE_URL=mysql://sync:test@127.0.0.1:3306/syncstorage_test SYNC_TOKENSERVER__DATABASE_URL=mysql://sync:test@127.0.0.1:3306/tokenserver_test RUST_TEST_THREADS=1 PYTHONPATH=\$($PY -c 'import site; print(site.getsitepackages()[0])')"
# A crate's tests run in each build that has them: a Spanner crate has none in a MySQL build, so its
# row there would pass with none. The runner has no Postgres server, so Postgres tests are CI only.
for c in $crates; do case "$c" in
  *spanner*|*postgres*) ;;
  *) row "test $c" "$TESTENV cargo nextest run --workspace --color never -E 'package($c)'" ;;
esac; done
for c in $crates; do case "$c" in *postgres*) row "test $c" "echo 'the runner has no Postgres server; CI runs $c tests'; exit 3" ;; esac; done
if [ "$server" = 1 ] || [ -n "$plan" ]; then
  row "restart server" "bash $SK/restart.sh"
  if [ -n "$plan" ]; then
    [ -s "$plan" ] || { echo "no plan at $plan" >&2; exit 2; }
    while IFS=$'\t' read -r n c; do [ -n "$c" ] && row "plan: $n" "$c"; done \
      < <(jq -r '.checks[]? | [.name, .cmd] | @tsv' "$plan")
  fi
  # The repo's own e2e suite against this server; its tokenserver tests need CI's mock FxA, so not here.
  row "integration tests" "cd $R && SYNC_SERVER_URL=http://localhost:8000 \
SYNC_MASTER_SECRET=\$(sed -n 's/^master_secret *= *\"\\(.*\\)\"/\\1/p' \$HOME/.syncstorage.toml) \
SYNC_SYNCSTORAGE__DATABASE_URL=mysql://sync:test@127.0.0.1:3306/syncstorage \
SYNC_TOKENSERVER__DATABASE_URL=mysql://sync:test@127.0.0.1:3306/tokenserver \
PYTHONPATH=$R $HOME/.syncstorage-it-venv/bin/python -m pytest tools/integration_tests -q -p no:cacheprovider --ignore=tools/integration_tests/tokenserver --ignore=tools/integration_tests/test_payload_link_reconciliation.py"
  row "sync protocol" "cd $SK/../sync-e2e && $PY e2e.py"
  [ "$ff" = 1 ] && row "firefox sync" "cd $SK/../sync-e2e && $PY firefox.py"
  # CI's reconciliation-e2e-tests job: the e2e suite on a Spanner server with payload offload and the
  # reconciler. spanner.sh wait exits 3 (SKIP) when the runner has no Spanner stack. The copy keeps
  # the Spanner binary; the MySQL build after it only relinks, so restart.sh still starts MySQL.
  SPENV="SYNC_SYNCSTORAGE__DATABASE_URL=spanner://projects/test-project/instances/test-instance/databases/test-database \
SYNC_SYNCSTORAGE__SPANNER_EMULATOR_HOST=localhost:9010"
  row "spanner build" "bash $SK/spanner.sh wait && CARGO_INCREMENTAL=0 cargo build --bin syncserver $SF \
&& cp target/debug/syncserver target/debug/syncserver-spanner && cargo build --bin syncserver $F"
  # CI's build-and-unit-test-spanner, for the changed crates that have Spanner tests.
  spx=""; for c in $crates; do case "$c" in *mysql*|*postgres*) ;; *) spx="${spx:+$spx | }package($c)" ;; esac; done
  [ -n "$spx" ] && row "unit tests (spanner)" "bash $SK/spanner.sh wait && SYNC_SPANNER_FEATURES='$SF' SYNC_MYSQL_FEATURES='$F' bash $SK/spanner.sh unit '$spx'"
  row "integration tests (spanner, offload)" "bash $SK/spanner.sh wait && bash $SK/spanner.sh up > /dev/null && cd $R && \
SYNC_SERVER_URL=http://localhost:8001 SYNC_MASTER_SECRET=\$(sed -n 's/^master_secret *= *\"\\(.*\\)\"/\\1/p' \$HOME/.syncstorage.toml) \
$SPENV GCS_PAYLOAD_BUCKET=test-payloads STORAGE_EMULATOR_HOST=http://localhost:4443 PUBSUB_EMULATOR_HOST=localhost:8085 \
PYTHONPATH=$R $HOME/.syncstorage-it-venv/bin/python -m pytest tools/integration_tests -q -p no:cacheprovider --ignore=tools/integration_tests/tokenserver"
fi

echo "changed: $(wc -w <<< "$changed" | tr -d ' ') file(s); crates: ${crates:-none}; server code: $([ "$server" = 1 ] && echo yes || echo no)"
if [ "$run" = 0 ]; then printf '%s\n' "${rows[@]}" | sed 's/^/  /'; echo "(the plan; --run runs it)"; exit 0; fi

verdict="" fail=0 log="$(mktemp)" vstart=$(date +%s)
for r in "${rows[@]}"; do
  n="${r%%$'\t'*}" c="${r#*$'\t'}" t0=$(date +%s)
  timeout 1200 bash -c "$c" > "$log" 2>&1; rc=$?
  if [ "$rc" = 0 ]; then v=PASS; elif [ "$rc" = 3 ]; then v=SKIP; cat "$log"; else v=FAIL; fail=1
    echo "── $n failed; the last lines:"; tail -25 "$log"; fi
  verdict="${verdict}$(printf '%-6s %-36s %4ss' "$v" "$n" "$(( $(date +%s) - t0 ))")"$'\n'
  # A broken build leaves nothing to test.
  [ "$v" = FAIL ] && [ "$n" = build ] && break
done
rm -f "$log"
grep -qE '^(syncstorage|tokenserver)-(db|mysql|postgres|spanner)' <<< "$crates" \
  && verdict="${verdict}The runner has no Postgres server, so no Postgres db test ran here. CI must run the Postgres suite."$'\n'
grep -q '^SKIP .*spanner' <<< "$verdict" \
  && verdict="${verdict}Some Spanner rows did not run here (the reasons are above). CI must run those Spanner suites."$'\n'
printf '\n%s' "$verdict" | tee "$W/.fxa-verify-verdict.txt"
# One line per run, in fxa-verify's shape, for the host's verify counts (_session_end_facts).
printf '{"at":%s,"mode":"full","rows":%s,"fail":%s,"secs":%s}\n' "$(date +%s)" "${#rows[@]}" "$(grep -c '^FAIL' <<< "$verdict")" \
  "$(( $(date +%s) - vstart ))" >> "$W/.fxa-verify-runs.jsonl" 2>/dev/null || true
[ "$fail" = 0 ] && echo "sync-verify: PASS" || echo "sync-verify: FAIL"
exit "$fail"
