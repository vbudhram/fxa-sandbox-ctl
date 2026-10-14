#!/usr/bin/env bash
# sync-verify: prove a syncstorage-rs change. Build, fmt, clippy and the changed crates' tests
# the CI way, then the change seen on the running server: the plan's own checks, the protocol
# check and a real Firefox sync. See SKILL.md.
#   verify.sh [--run] [--plan FILE] [--no-firefox]
set -uo pipefail
SK="$(cd "$(dirname "$0")" && pwd)" W="${SYNC_WORKSPACE:-/workspace}" PY="$HOME/.syncstorage-venv/bin/python"
cd "$W" || exit 2
export RUSTUP_HOME=/opt/rust/rustup PATH=/opt/rust/cargo/bin:$PATH
F="--no-default-features --features=syncstorage-db/mysql --features=py_verifier"
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
server=0; grep -qE '^(syncserver|syncstorage|tokenserver)[a-z-]*/' <<< "$changed" && server=1

rows=()  # "name<TAB>command"
row() { rows+=("$1"$'\t'"$2"); }
row build "cargo build --bin syncserver $F"
row fmt "cargo fmt --all -- --check"
row clippy "cargo clippy --workspace --all-targets $F -- -D clippy::dbg_macro -D warnings"
TESTENV="SYNC_SYNCSTORAGE__DATABASE_URL=mysql://sync:test@127.0.0.1:3306/syncstorage_test SYNC_TOKENSERVER__DATABASE_URL=mysql://sync:test@127.0.0.1:3306/tokenserver_test RUST_TEST_THREADS=1 PYTHONPATH=\$($PY -c 'import site; print(site.getsitepackages()[0])')"
for c in $crates; do row "test $c" "$TESTENV cargo nextest run --workspace --color never -E 'package($c)'"; done
if [ "$server" = 1 ] || [ -n "$plan" ]; then
  row "restart server" "bash $SK/restart.sh"
  if [ -n "$plan" ]; then
    [ -s "$plan" ] || { echo "no plan at $plan" >&2; exit 2; }
    while IFS=$'\t' read -r n c; do [ -n "$c" ] && row "plan: $n" "$c"; done \
      < <(jq -r '.checks[]? | [.name, .cmd] | @tsv' "$plan")
  fi
  # The repo's own e2e suite against this server; its tokenserver tests need CI's mock FxA, so not here.
  row "integration tests" "cd $W && SYNC_SERVER_URL=http://localhost:8000 \
SYNC_MASTER_SECRET=\$(sed -n 's/^master_secret *= *\"\\(.*\\)\"/\\1/p' \$HOME/.syncstorage.toml) \
SYNC_SYNCSTORAGE__DATABASE_URL=mysql://sync:test@127.0.0.1:3306/syncstorage \
SYNC_TOKENSERVER__DATABASE_URL=mysql://sync:test@127.0.0.1:3306/tokenserver \
PYTHONPATH=$W $HOME/.syncstorage-it-venv/bin/python -m pytest tools/integration_tests -q -p no:cacheprovider --ignore=tools/integration_tests/tokenserver --ignore=tools/integration_tests/test_payload_link_reconciliation.py"
  row "sync protocol" "cd $SK/../sync-e2e && $PY e2e.py"
  [ "$ff" = 1 ] && row "firefox sync" "cd $SK/../sync-e2e && $PY firefox.py"
fi

echo "changed: $(wc -w <<< "$changed" | tr -d ' ') file(s); crates: ${crates:-none}; server code: $([ "$server" = 1 ] && echo yes || echo no)"
if [ "$run" = 0 ]; then printf '%s\n' "${rows[@]}" | sed 's/^/  /'; echo "(the plan; --run runs it)"; exit 0; fi

verdict="" fail=0 log="$(mktemp)"
for r in "${rows[@]}"; do
  n="${r%%$'\t'*}" c="${r#*$'\t'}" t0=$(date +%s)
  if timeout 1200 bash -c "$c" > "$log" 2>&1; then v=PASS; else v=FAIL; fail=1
    echo "── $n failed; the last lines:"; tail -25 "$log"; fi
  verdict="${verdict}$(printf '%-6s %-28s %4ss' "$v" "$n" "$(( $(date +%s) - t0 ))")"$'\n'
  # A broken build leaves nothing to test.
  [ "$v" = FAIL ] && [ "$n" = build ] && break
done
rm -f "$log"
printf '\n%s' "$verdict" | tee "$W/.fxa-verify-verdict.txt"
[ "$fail" = 0 ] && echo "sync-verify: PASS" || echo "sync-verify: FAIL"
exit "$fail"
