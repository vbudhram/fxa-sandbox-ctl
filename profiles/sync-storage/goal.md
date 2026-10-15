1. You have printed a short plan: the root cause, the fix, and a test plan from /sync-verify in
   /workspace/.sync-test-plan.json, with checks that show the bug from outside. Wait for
   /run/fxa-profile/ready first, as your team rules say.
2. Before the fix, each plan check fails, and you printed that output.
3. 'bash ~/.claude/skills/sync-verify/verify.sh --run --plan /workspace/.sync-test-plan.json'
   shows no FAIL, and you printed its verdict table. A fix has a unit test that fails without it.
   Run long commands in the foreground with a timeout: a reply that waits on a background
   command ends the run.
4. /code-simplifier, then /sync-review (it runs /ponytail-review itself) have run on
   'git diff $(git merge-base HEAD origin/main)' plus untracked files, in one subagent that
   returns only its findings. You fixed each BLOCKER, and applied or declined (one line) the rest.
   After a fix, step 3 passes again.
5. **DO NOT COMMIT.** The host makes the commit. Print 'git status --short' and
   'git diff --stat', and revert any file unrelated to the ticket.
6. The change keeps the repo's rules: no edited published migration, no file from the list
   in the repo's CLAUDE.md, no change under .github/.
7. /create-pr-description on the step 4 diff, then /humanizer on it. pr_body keeps the
   headings of /workspace/PULL_REQUEST_TEMPLATE.md, with 'Closes <the Jira key>' under
   Issue(s), and the step 3 verdict table under Testing.
8. This team ships a patch, not a PR: pr_title and pr_body become its commit message and the
   Jira comment. Write them for the engineer who applies it with 'git am'.
