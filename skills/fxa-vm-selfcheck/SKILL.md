---
name: fxa-vm-selfcheck
description: Use inside the FxA sandbox VM after /fxa-review-quick and before the handoff. Runs the seven checks that FxA reviewers raise most often and that the repo review skills do not cover.
allowed-tools: Bash, Read, Grep, Glob
---

# FxA sandbox self-check

`/fxa-review-quick` from the repo covers FxA conventions, security, and
migrations. Run it first. This skill adds the seven checks that reviewers raised
on this pipeline's pull requests and that no repo skill performs.

Each check below traces to real review comments. Run all seven. Report a finding
only when you can name the file and the line.

## Run the script first

```bash
bash ~/.claude/skills/fxa-vm-selfcheck/check.sh
```

In one call it does Step 0, the test-line grep of Check 1, Check 3 (which
packages to compile), the frozen paths of Check 4, Check 6 and the tags of
Check 7. Fix each line that starts with `!`. Then do by hand only what needs
judgment: Check 1 (name the assertion that fails on a revert), Check 2, Check 5,
the file list of Check 4 against the request, and the skips and CI values of
Check 7. The sections below are the reference for each check.

## Step 0: Get the right diff

```bash
cd /workspace
BASE="$(git merge-base HEAD "origin/${FXA_WORKTREE_BASE:-main}")"
git --no-pager diff --stat "$BASE"
git --no-pager status --short
```

Review the diff from `$BASE`, never `HEAD` alone. It holds your commits and
your uncommitted edits; a pipeline run cannot commit, so its `HEAD` is an
upstream merge. A review of the wrong diff reports clean and teaches nothing.

Read every file that `git status --short` marks `??`. A diff hides an untracked
file, and a new test file is usually untracked.

## Check 1: The revert test

This is the most common finding against this pipeline. Seven pull requests
shipped a test that passes with or without the fix.

For every test the change adds or edits, answer one question: **which assertion
fails when I revert the source change?**

Name the assertion and the value it receives on unmodified code. When you cannot
name one, the test does not cover the fix. Fix the test. To prove it, run
`/fxa-verify --revert`: it runs the tests without the fix and with it.

Watch for these shapes:
- The test builds the input itself, so it never reaches the code you changed.
  A panel test that receives a prebuilt array passes whatever the server cap is.
- The assertion only checks that a field is `undefined`. An implementation that
  always returns `undefined` passes.
- The test asserts that a mock returned what the test told the mock to return.
- The test searches one field, so a leak in a sibling field passes.
- The assertion uses a default value (`undefined`, `false`, `""`, `[]`). Use a
  value that only the new code produces.
- The change moves a side effect, such as a success event or a cache write.
  Test that it happens on success, and that it does not happen on failure.
- A route spec mocks the helper you changed, so it proves nothing about it.

For a new guard, parser, or matcher, name where the value comes from: the DB
column, the API schema, or one real caller. List the values it can hold, such
as `null`, `""`, or a sentinel string. Add a test only for a value that takes a
different branch.

Then grep the test lines you added:

```bash
git --no-pager diff -U0 "$BASE" -- '*.test.tsx' | grep -nE '^\+.*(fireEvent|querySelector|ByTestId)'
```

Fix each hit as `.claude/rules/testing/react.md` says. Keep `ByTestId` only when
the element has no role and no visible text. To prove that something is absent,
use `queryBy` after the event settles. Do not reach an interaction the UI blocks
through `fireEvent`; test the control that the user can use.

Skip this check for a pure refactor, a config value, or an enum addition.

## Check 2: The other call sites

Seven pull requests fixed the site the ticket named and left the same defect in
a sibling path. One needed a second ticket and a second pull request.

```bash
git grep -n -- "<symbol>" -- '*.ts' '*.tsx' '*.js' | wc -l
```

1. List the symbols the change adds, renames, or edits. Take five at most.
   Skip a generic name such as `create` or `handler`.
2. Count the hits first. Add the owning package path when the count is over 40.
3. Read the hits outside your diff. Report a hit that carries the same defect.
4. When you guard or fix a write path, check the matching read path. A guard on
   the write path does not protect a value that another path already stored.
5. When you add a branch after an early return, or in code that several
   integrations reach (web, OAuth web, OAuth native), name each path to the
   changed line. Say which paths need the change.

When the change deletes or renames a symbol, route, CLI option, flag, or
package, search with no pathspec. CI config, Python, YAML and docs also hold
references:

```bash
git grep -n -- "<name>"
```

Read every hit.

Use `git grep`. It skips `node_modules` and build output. Do not assume the
ticket named every site.

## Check 3: Compile after a deletion or a signature change

Lint and Jest do not type-check. CI runs this as the `Build` job, and a failure
there stops every later job.

Run the compiler when the change deletes an export, renames a symbol, or edits a
function signature:

```bash
CFG=packages/<package>/tsconfig.build.json
[ -f "$CFG" ] || CFG=packages/<package>/tsconfig.json
npx tsc --noEmit -p "$CFG"
```

Do not use `yarn workspace <package> compile`. For `fxa-auth-server` that script
downloads a file first, and the VM has no network.

Some errors already exist on `main`. Report an error only when your change
touches the file it names.

Deleting an untyped fallback removes an inferred `any`, so a latent error can
appear for the first time. A clean `main` does not prove a clean branch.

## Check 4: Scope

```bash
git --no-pager diff --stat "$BASE"
```

Read the file list against the ticket. Revert a file the ticket does not need:

```bash
git checkout "$BASE" -- <path>
```

Do not restyle a file you had to touch. Do not extract a helper the ticket did
not ask for. A reviewer reads an unrelated file as a question, and the question
delays the whole change.

Check the frozen list before you defend an edit under `lib/senders`:

```bash
git show origin/main:_scripts/check-frozen.ts | sed -n '/^const frozen/,/^\];/p'
```

`yarn check:frozen` runs in the pre-commit hook, so an edit to a frozen path
cannot be committed. Read the list from the repo. Never work from memory: the
list changes in both directions, and a remembered entry invents a blocker.

## Check 5: The PR body claims

Run this check on `pr_body` after you write it (goal step 8), not at step 6.

For each claim in `pr_body`, name the diff line or the `it()` title that proves
it. Check numbers and limits, scope words such as "client-only" or "story-only",
"unchanged" or "untouched", and every "adds a test that". Delete a claim that
has no match. The host keeps the first round's body, so a wrong claim stays.

Then delete any production traffic number, rate, dashboard or Sentry reference, user data, or
security detail. The repo is public; see `create-pr-description`.

## Check 6: The test plan ran

When `/workspace/.fxa-test-plan.json` exists, the last `/fxa-verify --plan`
must cover it and must be newer than your last code change:

```bash
cd /workspace
cat .fxa-verify-verdict.txt
find . -path ./node_modules -prune -o -newer .fxa-verify-verdict.txt -type f \
  \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' \) -print | grep -v node_modules | head
```

- A file listed by `find` changed after the verdict: run `/fxa-verify --run
  --plan /workspace/.fxa-test-plan.json` again.
- The verdict has a `FAIL` or a `NONE` line: fix it, or say in the PR body why
  it is outside the change.
- A `TODO` line (Storybook): run `/fxa-storybook-capture` and list the files in
  `media_paths`.
- Each changed behavior in the diff must have a plan line. Add a missing one
  and run the plan again.

The PR body's testing section must match the verdict: every `plan` line with
its result, and every `CI` line with the reason it runs only in CI.

## Check 7: New or changed functional specs

A spec can pass on the VM and fail in CI. The CircleCI `playwright-functional-tests`
job runs every spec with its own environment. The `smoke-tests` job runs every
spec against stage and production, not only the `#smoke` specs.

```bash
cd /workspace
git --no-pager diff --name-only --diff-filter=AM "$BASE" -- packages/functional-tests/tests/
git ls-files --others --exclude-standard -- packages/functional-tests/tests/
git show "origin/${FXA_WORKTREE_BASE:-main}:.circleci/config.yml" \
  | awk '/^  functional-test-executor:/{f=1;next} f&&/^  [a-z]/{exit} f' | grep -E '^ +[A-Z][A-Z0-9_]+:'
```

Skip this check when the first two commands print nothing. For each spec they
print, read the whole file and one or two specs in the same directory:

```bash
grep -nE "describe\('severity-|#smoke|#phone|test\.(skip|fixme)\(|project\.name|featureFlags\." <spec> <neighbour-spec>
```

Report a finding when one of these is true:
- The spec has no `severity-N` or `#smoke` in its `test.describe` title, but the
  neighbours have one. A test that sends SMS has no `#phone`. CI runs `#phone`
  tests serially and removes them from the main run.
- A test needs something that stage or production does not have, and has no
  skip. Examples are a local-only client, a flag, or a service. Use the skip
  that neighbours use, such as `test.skip(project.name === 'production', '<reason>')`
  or a `configPage.getConfig()` flag check.
- An assertion needs a value that the CI environment above does not give. CI sets
  `GEODB_LOCATION_OVERRIDE` to a country code and a postal code only, so an
  asserted city or region fails. A flag that CI does not set and that is off by
  default in the service config also fails.

## Output

Report one line per finding: the check, the file and line, and the fix.

Report `Self-check passed: <n> checks, no findings.` when you find nothing. Do
not list what you checked and found correct.

Fix what you find, then run `/fxa-review-quick` again. Every fix changes the
diff that the review read.
