---
name: fxa-test-plan
description: Use inside the FxA sandbox before you change code. Decide, from the ticket or request, which tests prove each behavior you will change (unit, integration, functional, Storybook, or CI only), write them to /workspace/.fxa-test-plan.json, and let /fxa-verify --plan run them. Use again when the plan changes.
allowed-tools: Bash, Read, Write, Grep, Glob
---

# FxA test plan

`/fxa-verify` on its own runs the specs that import the files you touched. That
shows nothing broke. It does not show that the ticket's behavior works. Only
you know that behavior, so you choose the tests that prove it, before you write
the code.

## Step 1: List the behaviors

Read the ticket (`/workspace/.fxa-jira-context.md`) or the request. Write one
line for each behavior that changes, as something a test can check:

- Good: "GET /v1/verify_email returns 404 after the route is removed."
- Bad: "Remove the legacy route." That is the change, not the behavior.

A removal has behaviors too: what now fails or is absent, and what must still
work.

## Step 2: Pick the narrowest level that proves each one

| Level | Use it for | Cost here |
|---|---|---|
| `unit` | Logic in one module: a function, a component's render, a validator | seconds |
| `integration` | An auth route, the database, Redis, a customs or email path (`*.in.spec.ts`) | 10-25 s, runs the DB patcher first |
| `scripts` | An auth script under `test/scripts/` | about 13 s |
| `oauth-api` | `test/remote/oauth_api.in.spec.ts` only | about 13 s |
| `storybook` | How a component looks; run `/fxa-storybook-capture` | manual |
| `functional` | A flow across pages or services that no lower level can show | 2 min stack start plus the spec; at most one per plan |
| `types` | A removal, rename or signature change: type-check the touched projects | 2-11 s |
| `ci` | What cannot run here (see below); CI covers it | none |

Go up a level only when the lower one cannot show the behavior. A route change
is an integration test, not a functional one. A copy change in a component is a
unit test and a screenshot.

Each changed behavior needs a test that fails if you revert the change. If no
existing spec does that, plan a new one and write it.

## Step 3: Find the specs

Search for existing specs before you plan a new one:

```bash
git grep -ln '<route or symbol>' -- '*.spec.ts' '*.test.tsx' '*.in.spec.ts' 'packages/functional-tests/tests'
```

Put a new spec next to the nearest similar one, with the same naming.

## Step 4: Write the plan

`/workspace/.fxa-test-plan.json` (the `.fxa-` prefix keeps it out of the commit):

```json
{
  "items": [
    { "behavior": "GET /v1/verify_email returns 404", "level": "integration",
      "spec": "packages/fxa-auth-server/test/remote/misc_tests.in.spec.ts", "new": false,
      "why": "the route is in the auth server and needs the database" },
    { "behavior": "the swagger doc no longer lists the route", "level": "unit",
      "spec": "packages/fxa-auth-server/docs/swagger/util-api.spec.ts", "new": true,
      "why": "no spec covers the doc today" },
    { "behavior": "sign-in with a verification link still works", "level": "functional",
      "spec": "packages/functional-tests/tests/signin/signIn.spec.ts",
      "grep": "login as an existing user", "new": false,
      "why": "the link path crosses the content server and auth" },
    { "behavior": "OAuth relier sign-in is unchanged", "level": "ci",
      "why": "relier flows need the subscriptions capability manager, which is off here" }
  ]
}
```

- `spec` is a path from `/workspace`. For `functional`, `grep` picks one test in
  the spec. `ci` and `types` need no spec.
- Print the plan in the transcript. In a Slack session, it is part of your
  first-turn plan, so the person can change it before you code.

## Step 5: Run it

```bash
bash ~/.claude/skills/fxa-verify/verify.sh --run --plan /workspace/.fxa-test-plan.json
```

It runs, in this order:
1. The planned specs, each in the right runner and Jest project. Those are the
   `plan` lines.
2. The related specs of every changed file, as a safety net. Those are the
   `net` lines.
3. The functional spec, last. It starts the stack if needed.

The verdict marks `ci` lines as `CI` and `storybook` lines as `TODO`, and a
missing spec as `FAIL`. A `net` line with `NOREL` means no spec imports that
file; that is fine only when a `plan` line covers its behavior. It writes the verdict to
`/workspace/.fxa-verify-verdict.txt`.

## Limits here

- These run only in CI; plan them as `ci`: OAuth relier flows through 123done
  (`tests/oauth/*`, `loginHint*`, `relayIntegration`, `smartWindowIntegration`),
  the CMS specs (`tests/cms/*`), payments (`local-payments-next`), and
  payments-next unit tests.
- One functional spec at most. With the stack up, a 2-worker functional run
  used 6.85GB of 7.9GB. Run nothing else at the same time.
- `signIn.spec.ts` "servicesWithEmailVerification RP gets exactly one
  verifyLoginCode email" fails here on main. Pick another test from that spec.
- Never plan a whole suite.

## In the PR body

The testing section lists each plan line with its verdict: what ran and passed,
what CI covers, and why. A reviewer reads this to know what was proved.
