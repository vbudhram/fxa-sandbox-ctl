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

With no file paths it checks every change in the working tree, including
changes an earlier run left on this slot. Read `git status` first; if the plan
names files you did not change, pass your own paths instead.

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
  VM runs at boot, and the DB tables, which only the patcher creates. The
  helper runs `node packages/db-migrations/bin/patcher.mjs` first; without it
  the suite waits 63 s and fails on `ER_NO_SUCH_TABLE`. Do not run two
  integration suites at once. To see why an integration setup failed, rerun
  with `REMOTE_TEST_LOGS=true` (and `MAIL_HELPER_LOGS=true`).
- fxa-auth-server one test: `yarn test <spec> -t "<name>" --verbose`; `yarn
  test` forwards paths and flags, `nx test-unit` does not.
- fxa-admin-server: its Jest maps `@fxa/*` to a `dist/` that exists only after
  `fxa-start` builds it. The helper adds `--modulePaths=/workspace` so the
  library source is used.
- fxa-auth-client is mocha (`test/<name>.ts`), not Jest; Jest finds 0 tests.
- libs/*: `npx jest -c <config> --findRelatedTests` is the fastest form. (`nx
  test-unit <lib> --testFile` does run just that file, but through Nx.)
- Lint: the helper runs `npx eslint` on the changed files, 1-2 s. `npx nx
  lint <p>` also works but is slower (20 s for fxa-auth-server): for auth,
  content and shared its glean step first installs `glean_parser` from PyPI.
- Jest versions differ by package (27, 29, 30): always run from the package
  directory with its local `npx jest`.
- Nx caches `@nx/jest` results; a cached pass proves nothing new. The helper
  calls Jest directly.
- Never run a whole package suite: with the stack up it runs this 8 GB runner
  out of memory. CI runs the full suites.

## What it cannot cover

- fxa-content-server and 123done have no unit tests: use `/fxa-functional-local`.
- fxa-shared: the helper runs the mirrored `test/<path>.spec.ts` with mocha
  (unit tests only) and `nestjs/` with Jest. A file with no mirrored spec is
  reported, not tested.
- payments-next (`apps/payments/next`): all its Jest suites fail to transform
  in the VM on main (babel-jest 30 under Jest 29), so the helper skips them and
  says so. Its type-check and lint work. CI covers the tests.
- `--types` skips fxa-profile-server and functional-tests: `tsc` already fails
  on main there, and CI does not type-check them.
- UI and flows: `/fxa-functional-local`. Screenshots: `/fxa-storybook-capture`.

## Speeds measured in the VM (4 vCPU, 8 GB)

| Check | Time | Peak memory |
|---|---|---|
| one auth unit spec (`yarn test <spec>`) | 3-8 s | 0.3-0.8 GB |
| one auth integration spec, after the patcher | 10-12 s | 0.8 GB |
| settings sibling spec | 2 s | 0.4 GB |
| `tsc --noEmit`: settings / libs (`-p tsconfig.lib.json`) | 2 s / 1.3 s | 0.6 GB |
| `tsc --noEmit`: auth (`-p tsconfig.build.json`) / admin-server | 11 s / 9.5 s | 2.5 / 2.2 GB |
| `eslint` on a few files | 1-2 s | 0.3 GB |

## If a check fails

Read the last lines the helper printed and the log it names. Fix the code, not
the test, unless the test asserts the old behaviour the change was meant to
replace. Run the helper again until the verdict is all PASS, or report the
failure plainly if it is outside the change.
