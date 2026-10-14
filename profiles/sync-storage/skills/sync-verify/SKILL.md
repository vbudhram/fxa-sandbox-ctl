---
name: sync-verify
description: Verify a syncstorage-rs change in the Sync Storage sandbox, the way fxa-verify does for FxA. Builds, runs fmt and clippy as CI does, runs the tests of each changed crate the CI way, then rebuilds and restarts the server and proves the fix on it: your own reproduction checks, the Sync protocol check, and a real Firefox sync. Prints a verdict table. Use before you say a fix works, and before the handoff.
---

# Verify a change

1. Write a test plan before you change code: `/workspace/.sync-test-plan.json`. Each check is a
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
   bash ~/.claude/skills/sync-verify/verify.sh --plan /workspace/.sync-test-plan.json         # the plan
   bash ~/.claude/skills/sync-verify/verify.sh --run --plan /workspace/.sync-test-plan.json   # run it
   ```
   It runs, in order: build, `cargo fmt --check`, clippy (`-D warnings`), the tests of each
   changed crate with `cargo nextest run --workspace -E 'package(<crate>)'` on the test
   databases, then (when server code or a plan changed) a rebuild and restart of the server,
   your plan's checks, the repo's integration tests (`tools/integration_tests`, with a venv the
   boot made from their own lock; the tokenserver tests need CI's mock FxA and the payload-link one
   needs GCP, so both are left out), the
   protocol check and the Firefox sync. `--no-firefox` skips Firefox.
   To add an e2e test, put it in `tools/integration_tests` and run the suite with the
   "integration tests" command from the plan.
3. Fix each FAIL and run it again. Before the handoff, the whole run shows no FAIL. Print the
   verdict table (also in `/workspace/.fxa-verify-verdict.txt`) in your reply.

A change with no server code (docs, tools) skips the server steps. Unit tests alone never prove
a fix that a client can see: the plan's checks do.
