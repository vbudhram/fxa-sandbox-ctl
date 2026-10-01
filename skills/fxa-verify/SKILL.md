---
name: fxa-verify
description: Verify a change in the FxA monorepo on the sandbox VM with the fastest correct checks. Maps each changed file to its package and runs only the related unit tests, lint, a Prettier check and a type-check on the changed files, then prints a verdict table. Use before saying tests pass, and before the handoff.
---

# Verify a change

Run the helper. It reads the working diff against origin/main (untracked files
included), plans one command per package, and with `--run` runs them:

    bash ~/.claude/skills/fxa-verify/verify.sh             # show the plan
    bash ~/.claude/skills/fxa-verify/verify.sh --run       # run it, print the verdict
    bash ~/.claude/skills/fxa-verify/verify.sh --run --no-types   # skip the type-check for a quick rerun
    bash ~/.claude/skills/fxa-verify/verify.sh --run --plan /workspace/.fxa-test-plan.json

With `--plan` it first runs the specs your test plan names (`plan` lines; see
`/fxa-test-plan`), then the related specs of the changed files (`net` lines),
then the planned `check` lines and functional specs, last, with the stack started once. `CI` and `TODO` lines are not run. Every
run writes its verdict to `/workspace/.fxa-verify-verdict.txt`.

Verdicts: `PASS`; `FAIL`; `NONE` (the command ran no tests: fix the command or
the spec); `NOREL` (no spec imports that file, for example a route that only
integration specs cover: your test plan must cover it); `CI` (left to CI);
`TODO` (Storybook, by hand).

Each touched project gets lint, a Prettier check, and a type-check. The App
commits through the API, so no hook formats your change: fix a `format` FAIL
with `npx prettier --write <files>`. Pass file paths to check only those. Print the verdict table in your reply: it is the evidence.

With no file paths it checks every change in the working tree, including
changes an earlier run left on this slot. Read `git status` first; if the plan
names files you did not change, pass your own paths instead.

## Prove that the tests fail without the fix (`--revert`)

Use `--revert` when you must show that a new or changed test catches the bug,
for example for the PR body or the self-check:

    bash ~/.claude/skills/fxa-verify/verify.sh --revert                  # the test files in the diff
    bash ~/.claude/skills/fxa-verify/verify.sh --revert <spec> [<spec>...]

1. It backs up the non-test files in the diff against the merge-base.
2. It writes their merge-base versions with `git show`. It removes the new
   files of the fix, tracked or untracked. It does not touch the index.
3. It runs the tests, then puts the fixed files back and runs the tests again.
4. It prints a table: test, without the fix, with the fix.

It exits 0 only when every test fails without the fix and passes with it. A
test that passes without the fix does not prove the change: the table flags it.
With no test files in the diff and no specs given, it runs the related tests of
the fix.

A trap puts the fixed files back on every exit, also on a failure or Ctrl-C.
It then compares their checksums. If they do not match, it prints where the
backup is. When the auth server is up and server files changed, it waits for
`localhost:9000/__heartbeat__` after each swap.

Do not revert by hand with `git stash` or `git checkout`: `git stash` fails on
a staged file, and `git checkout` changes the index. Settings hot reload has no
wait, so a functional spec that runs directly after the swap can see the old
bundle.

## How it picks tests

For Jest projects it uses Jest's own `--findRelatedTests`, so a source change
runs every spec that imports it. When more than 15 specs relate (a widely used
file), it runs the sibling spec only and says so. Full logs are in /tmp/fxa-verify/.

## Traps it avoids (do not work around them by hand)

- fxa-settings: `nx test-unit` only prints "No unit tests present". Its tests
  run through `node scripts/test.js`, and without `CI=true --watchAll=false`
  that starts watch mode and hangs.
- fxa-auth-server: `nx test-unit --testFile` is ignored; only `yarn test`
  forwards arguments. Its Jest has four projects: `unit` (`*.spec.ts`),
  `integration` (`*.in.spec.ts`), `scripts` (`test/scripts/*.in.spec.ts`) and
  `oauth-api` (`test/remote/oauth_api.in.spec.ts`). `integration` ignores the
  last two, so the helper sends each file to its own project with
  `--selectProjects`. The three infra-backed projects need MySQL, Redis, and Firestore, which the
  VM runs at boot, and the DB tables, which only the patcher creates. The
  helper runs `node packages/db-migrations/bin/patcher.mjs` first; without it
  the suite waits 63 s and fails on `ER_NO_SUCH_TABLE`. Do not run two
  integration suites at once. To see why an integration setup failed, rerun
  with `REMOTE_TEST_LOGS=true` (and `MAIL_HELPER_LOGS=true`).
- fxa-auth-server one test: `yarn test <spec> -t "<name>" --verbose`; `yarn
  test` forwards paths and flags, `nx test-unit` does not.
- fxa-auth-server unit tests fail in `config/index.spec.ts` when
  `SNS_TOPIC_ENDPOINT` is set, and `/etc/agent-env.sh` sets it for the goaws
  stub. The helper runs unit tests with `env -u SNS_TOPIC_ENDPOINT`; do the
  same by hand. Integration tests keep it.
- `--selectProjects` takes several values, so `npx jest --selectProjects unit
  <spec>` reads the spec as a project name and runs the whole project. Put a
  flag between them (`--selectProjects unit --forceExit <spec>`).
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
- fxa-profile-server and functional-tests: `tsc` already fails on main in the
  VM, so the type-check fails only on errors in the changed files. CI's
  `compile` target type-checks the whole project.
- UI and flows: `/fxa-functional-local`. Screenshots: `/fxa-storybook-capture`.

## Speeds measured in the VM (4 vCPU)

`tsc` is incremental (`tsconfig.base.json`), so only the first run in a
session pays the cold time.

| Check | Time | Peak memory |
|---|---|---|
| one auth unit spec (`yarn test <spec>`) | 3-8 s | 0.3-0.8 GB |
| one auth integration spec, after the patcher | 10-12 s | 0.8 GB |
| settings sibling spec | 2 s | 0.4 GB |
| `tsc --noEmit`: settings / libs (`-p tsconfig.lib.json`) | 2 s / 1.3 s (cold 10 s / 4 s) | 0.6 GB |
| `tsc --noEmit`: auth (`-p tsconfig.build.json`) / admin-server | 9-11 s / 9.5 s (auth cold 14-23 s) | 2.2-2.5 / 2.2 GB |
| `tsc --noEmit`: functional-tests | 4 s | 0.45 GB |
| `eslint` / `prettier --check` on a few files | 1-2 s / 1 s | 0.3 GB |
| auth `scripts` or `oauth-api` spec, after the patcher | 13 s | 1.4 GB |

The whole auth unit project (173 suites, 4157 tests) passed on main with
`SNS_TOPIC_ENDPOINT` unset. Jest defaults to CPUs - 1 = 3 workers here, and
each worker grows as it loads more test files:

| Workers | Time | Lowest free memory (stack off) |
|---|---|---|
| 3 (default) | 87 s | 0.2 GB |
| 2 (`--maxWorkers=2`, what the helper passes for auth) | 105 s | 0.5 GB |
| 1 (all files in one process, which grew to 4.3 GB) | 166 s | 2.5 GB |

The stack takes about 2.8 GB more, so with it up even 2 workers would run out
of memory on the whole project. Run only related specs.

## If a check fails

Read the last lines the helper printed and the log it names. Fix the code, not
the test, unless the test asserts the old behaviour the change was meant to
replace. Run the helper again until the verdict is all PASS, or report the
failure plainly if it is outside the change.
