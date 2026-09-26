---
name: fxa-verify
description: Verify a change in the FxA monorepo on the sandbox VM with the fastest correct checks. Maps each changed file to its package and runs only the related unit tests, lint on the changed files, and an optional type-check, then prints a verdict table. Use before saying tests pass, and before the handoff.
---

# Verify a change

Run the helper. It reads the working diff against origin/main (untracked files
included), plans one command per package, and with `--run` runs them:

    bash ~/.claude/skills/fxa-verify/verify.sh             # show the plan
    bash ~/.claude/skills/fxa-verify/verify.sh --run       # run it, print the verdict
    bash ~/.claude/skills/fxa-verify/verify.sh --run --types   # also type-check the touched projects

Add `--types` for any removal, rename, or signature change. Pass file paths to
check only those. Print the verdict table in your reply: it is the evidence.

## How it picks tests

For Jest projects it uses Jest's own `--findRelatedTests`, so a source change
runs every spec that imports it. When more than 15 specs relate (a widely used
file), it runs the sibling spec only and says so. Full logs are in /tmp/fxa-verify/.

## Traps it avoids (do not work around them by hand)

- fxa-settings: `nx test-unit` only prints "No unit tests present". Its tests
  run through `node scripts/test.js`, and without `CI=true --watchAll=false`
  that starts watch mode and hangs.
- fxa-auth-server: `nx test-unit --testFile` is ignored; only `yarn test`
  forwards arguments. `*.in.spec.ts` integration tests run in the
  `integration` Jest project and need MySQL, Redis, and Firestore, which the
  VM runs at boot. Do not run two integration suites at once.
- libs/*: `nx test-unit <lib> --testFile` runs the whole suite, because Jest
  ORs positional patterns with the target's own. Use `npx jest -c <config>`.
- Jest versions differ by package (27, 29, 30): always run from the package
  directory with its local `npx jest`.
- Nx caches `@nx/jest` results; a cached pass proves nothing new. The helper
  calls Jest directly.
- Never run a whole package suite: with the stack up it runs this 8 GB runner
  out of memory. CI runs the full suites.

## What it cannot cover

- fxa-content-server has no unit runner: use `/fxa-functional-local`.
- fxa-shared tests are mocha under `test/`: run the mirrored file with
  `TS_NODE_PROJECT=tsconfig.cjs.json npx mocha -r ts-node/register/transpile-only -r tsconfig-paths/register -r ./scripts/preload-chai.mjs test/<file>.ts`
  from `packages/fxa-shared` (add `-g '#integration' --invert` for unit only).
- UI and flows: `/fxa-functional-local`. Screenshots: `/fxa-storybook-capture`.

## If a check fails

Read the last lines the helper printed and the log it names. Fix the code, not
the test, unless the test asserts the old behaviour the change was meant to
replace. Run the helper again until the verdict is all PASS, or report the
failure plainly if it is outside the change.
