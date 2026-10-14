---
name: sync-review
description: Review your own syncstorage-rs change before the handoff, the way fxa-review-quick does for FxA. Runs the repo's own review skills that match the diff (rust-error-review, multi-backend-consistency, migration-review), a short checklist of what Sync reviewers flag, then ponytail-review. Returns findings with a severity; fix each blocker.
---

# Review a Sync Storage change

The target is `git diff $(git merge-base HEAD origin/main)` plus untracked files. HEAD lacks
your work. Run this in a subagent that returns only the findings.

1. Run each of the repo's own review skills (in `/workspace/.claude/`) that the diff touches:
   | The diff touches | Run |
   |---|---|
   | an error type or variant, an `is_sentry_event`, an HTTP status | `rust-error-review` |
   | a trait in `syncstorage-db*` or `tokenserver-db*`, or one backend crate | `multi-backend-consistency` |
   | a migration or a schema file | the `migration-review` command |
   Skip what needs Spanner or GCP: the sandbox has MySQL only. Say so in the findings.
2. Check the diff against what Sync reviewers flag:
   - **Auth:** no path that skips Hawk or the token check; a token or key never logged.
   - **Errors:** a client error is a 4xx with the documented body, never a 500; a new error
     is routed to Sentry or kept out on purpose.
   - **Backends:** the MySQL, Postgres and Spanner code agree; a Spanner-only path is marked.
   - **Limits:** batch, payload and record limits still apply on every new path.
   - **Migrations:** a published migration is never edited; a new one has its rollback.
   - **Tests:** the fix has a test that fails without it, and a plan check from `/sync-verify`.
3. Run `/ponytail-review` on the diff.
4. Return a list: BLOCKER, SHOULD or NIT, the file and line, one line on what and why. A
   BLOCKER is a fault a user or an operator meets. Return "no findings" when there are none.
