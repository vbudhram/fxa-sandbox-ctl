---
name: sync-verify
description: Verify a syncstorage-rs change in the Sync Storage sandbox, the way fxa-verify does for FxA. Builds, runs fmt and clippy as CI does, runs the tests of each changed crate the CI way, then rebuilds and restarts the server and proves the fix on it: your own reproduction checks, the Sync protocol check, and a real Firefox sync. Prints a verdict table. Use before you say a fix works, and before the handoff.
---

# Verify a change

1. Write a test plan before you change code: `/workspace/.fxa-sync-test-plan.json`. Each check is a
   command that shows the bug from outside, the way Firefox or a client meets it: a `curl` to
   the token server or storage on :8000, a SQL read, or a Python step with PyFxA. A check must
   fail before the fix and pass after it. Run it once before the fix and keep that output.
   ```json
   {"checks": [{"name": "an expired token gets 401, not 500",
                "cmd": "curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer x' localhost:8000/1.0/sync/1.5 | grep -qx 401"}]}
   ```
   For a check that needs an account, a token and Hawk credentials, import from
   `~/.claude/skills/sync-e2e/e2e.py` (`confirm`, `hawk`, `http`).
   **Batches:** a check of the batch path opens, appends and commits in separate requests.
   `?batch=true&commit=true` in one request never touches the batch tables, so a check written
   that way passes on the old code too and proves nothing.
2. Show the plan, then run it:
   ```
   bash ~/.claude/skills/sync-verify/verify.sh --plan /workspace/.fxa-sync-test-plan.json         # the plan
   bash ~/.claude/skills/sync-verify/verify.sh --run --plan /workspace/.fxa-sync-test-plan.json   # run it
   ```
   It runs, in order: build, `cargo fmt --check`, clippy (`-D warnings`), the tests of each
   changed crate with `cargo nextest run --workspace -E 'package(<crate>)'` on the test
   databases, then (when server code or a plan changed) a rebuild and restart of the server,
   your plan's checks, the repo's integration tests (`tools/integration_tests`, with a venv the
   boot made from their own lock; the tokenserver tests need CI's mock FxA, so they are left out,
   and the payload-link one runs in the Spanner row below), the
   protocol check and the Firefox sync. `--no-firefox` skips Firefox.
   It also runs what CI runs for the other backends, so a CI failure shows here first:
   - clippy with the Spanner and the Postgres features (code behind a feature compiles only there);
   - `ruff format --diff tools` and `ruff check tools`, when a Python file in `tools/` changed;
   - for server code: a Spanner build, the changed crates' unit tests on the Spanner emulator (as
     CI's `build-and-unit-test-spanner`; SKIP under 4 GB free disk), then the integration tests on a
     Spanner server (:8001) with payload offload, fake GCS and the payload-link reconciler, as CI's
     `reconciliation-e2e-tests` job runs them.
   The boot builds the Spanner stack after the MySQL server is ready (`/run/fxa-profile/spanner-ready`),
   so the first Spanner row can wait for it. `bash ~/.claude/skills/sync-verify/spanner.sh up` starts
   that stack alone, for a reproduction; its logs are in `~/.syncstorage-spanner/`.
   To add an e2e test, put it in `tools/integration_tests` and run the suite with the
   "integration tests" command from the plan. To run one test, add `-k <name>` to that command.
   Use the boot's venv, `~/.syncstorage-it-venv`: the runner has no poetry, and do not make or
   change a venv, since the boot pins it to the tests' own lock.
3. Fix each FAIL and run it again. Before the handoff, the whole run shows no FAIL. Print the
   verdict table (also in `/workspace/.fxa-verify-verdict.txt`) in your reply.
   A SKIP row is a test this runner cannot run (Postgres has no server here). Copy its reason and
   the note under the table into the PR body, so a reviewer knows that only CI tests that part.
   An `ENV` line under a SKIP row means this runner lacks a tool it should have. The operator is
   told. Do not stop or block for it: hand off with the SKIP and its reason in the PR body.

A change with no server code (docs, tools) skips the server steps. Unit tests alone never prove
a fix that a client can see: the plan's checks do.
