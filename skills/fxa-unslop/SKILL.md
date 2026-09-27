---
name: fxa-unslop
description: Use inside the FxA sandbox on your own change before the handoff. Checks the diff, the tests and the PR body for what reviewers of FxA agent PRs flag again and again, and fixes it. Run after /code-simplifier and /ponytail-review, and again on the PR body after /humanizer.
allowed-tools: Bash, Read, Edit, Grep
---

# FxA unslop

Reviewers read 126 pull requests from this agent. About 108 of their findings
were not logic bugs. They were habits: tests that do not protect the change,
leftovers after a removal, a PR body that claims more than the diff does.
This skill finds those habits in your change before a reviewer does.

It covers your diff and your words. General prose cleanup belongs to
/humanizer; logic review belongs to /fxa-review-quick. The FxA repo has its own
rules in `/workspace/.claude/rules/` (code comments, testing, metrics). Those
win where they are more specific than this file.

The review target is always the whole change:

```bash
cd /workspace
git diff "$(git merge-base HEAD origin/main)" --stat
git status --short    # untracked files are part of the change too
```

## Part 1: the diff

Go through each check. Fix what fails. Write one line per check in the
transcript: `pass`, `fixed: <what>`, or `n/a`.

1. **Tests protect the change.** This was the largest group, about 50 findings.
   - For each behavior you changed, name the test that fails if you revert
     that change. If no test would fail, write one.
   - When you delete a test, replace its coverage or say in the PR body why
     the behavior is gone.
   - Check that the test target really runs. `fxa-settings` `test-unit` is
     `echo No unit tests present`, so it proves nothing; run the spec with
     Jest directly. Look at the target in `package.json` or `project.json`
     before you cite it.
   - Follow `/workspace/.claude/rules/testing/*.md`: role and label queries
     over `data-testid` and CSS selectors, `userEvent` over `fireEvent`,
     `renderHook` for hooks, one assertion surface per test, and asserts on
     what the user sees, not on mocks or default copy that may change.

2. **A removal leaves nothing behind.** About 15 findings.
   When you remove or move a flag, route, param, component or dependency,
   search for every other use and delete the orphans:
   ```bash
   git grep -n '<name>' -- . ':!**/node_modules/**'
   git grep -n '<name>' -- .circleci .github 'packages/*/package.json'
   ```
   Check config keys, feature flags, CSS, imports, CI jobs and package
   scripts. For an auth-server route or param, also check known clients
   (PyFxA, the Firefox desktop and mobile clients) and say in the PR body
   what you could not check.

3. **Reuse before you write.** Before you add a helper, a config value or a
   type, search for an existing one (`git grep`, the package's `lib/`, the
   typed `AuthClient` methods). Keep a well-known npm package instead of a
   hand-written copy of it.

4. **Names follow behavior.** When a function's behavior changes, rename it.
   Do not give a new symbol the name of a well-known package.

5. **Types at the boundaries you touch.** Widen the declared type instead of
   casting. Narrow `unknown` before you read a field from it. Do not leave a
   new option inside an `any`.

6. **Comments state only what the code guarantees.** Follow
   `/workspace/.claude/rules/code-comments.md`. Also:
   - Delete comments that guess about callers or other code.
   - One short line that says why. Never what the next line does.
   - No Jira keys or issue numbers in code.
   - After your change, re-read the comments, docs and README lines near it.
     Fix the ones your change made wrong.

7. **Strings.** When English text changes, give the string a new FTL ID.
   Keep one sentence in one translatable unit. Do not remove a localized
   variant.

8. **Storybook.** Each story supplies its own providers (`<Localized>`,
   app context) and stubs every network call. A story must not change globals
   such as the user agent.

9. **Logging and metrics.** When you port or split a code path, keep its log
   and metric events (see `/workspace/.claude/rules/metrics-flow.md`). Log the
   failure branch. Never log a full URL, a token or an email.

10. **Scope and test data.** Every hunk must trace to the ticket or request.
    Revert the rest with `git checkout -- <path>` and list it in the PR body
    as a follow-up. Test emails are obviously fake, such as
    `user@example.com`.

## Part 2: the words

Run this on the PR body after /create-pr-description and /humanizer, and on
the commit title.

1. **Every claim matches the diff.** Read the body line by line against
   `git diff`. Remove any rename, file, number or limit that the diff does
   not contain. A body that says "no page source changed" while the diff
   changes a component is the most common false claim.

2. **Evidence is what you ran.** Write "I ran `<command>`: 42 passed" or
   "Not run: <reason>". Never call unverified work tested or working. Name
   what CI will cover and what nobody checked. A skipped step is reported as
   skipped.

3. **Say what a reviewer must decide.** Reviewers approved PRs faster when the
   body had one line that names the single decision they must make, such as
   "One reviewer call: keep the legacy route for one more train?". Also say
   what you kept on purpose and why.

4. **Plain wording.**
   - ASD-STE100 style: short sentences, active voice, simple tenses, one word
     for one meaning. Write "use", not "utilize".
   - No em dashes. Use a comma or a new sentence.
   - Write "FxA", not "FXA" or "fxa", in prose.
   - No praise, no enthusiasm, no summary of how good the change is.
   - Banned in the body and the commit: comprehensive, robust, seamless,
     significantly improved, enhanced, various improvements. Name the change.

5. **The title.** A scoped conventional commit, as the repo uses:
   `fix(auth): stop sending the stale session token`. Imperative mood, at most
   72 characters, no trailing period.

## Report

End with the Part 1 lines and one line for Part 2, for example:

```
fxa-unslop: tests fixed (added revert-proof spec for ...); removal pass;
reuse n/a; names pass; types fixed (...); comments fixed (...); strings n/a;
storybook n/a; logging pass; scope pass. Words: 2 claims removed, evidence
lines added.
```

Credits: the honesty and commit rules adapt maxgoff/unslop (MIT). The
patterns come from review comments on this agent's pull requests in
mozilla/fxa.
