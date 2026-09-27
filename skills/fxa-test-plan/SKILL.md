---
name: fxa-test-plan
description: Use inside the FxA sandbox before you change code. Plan how you will prove each behavior the ticket changes, the way a user or client would see it (a functional flow, a direct check against the running stack, an integration spec), with unit tests for edge cases. Write it to /workspace/.fxa-test-plan.json and let /fxa-verify --plan run it. Use again when the plan changes.
allowed-tools: Bash, Read, Write, Grep, Glob
---

# FxA test plan

`/fxa-verify` on its own runs the specs that import the files you touched. That
shows nothing broke. It does not show that the ticket's behavior works. Only
you know that behavior, so before you write code you decide how you will
**see** it work.

Lean toward verification. A unit test proves that a function returns what you
expect. It does not prove that a user can sign in, or that a client gets a 404.
For every change a user or a client can observe, the plan must include at least
one check that observes it on the running stack or through the real server.
Unit tests come on top, for the edge cases and as the regression test.

## Step 1: List the behaviors

Read the ticket (`/workspace/.fxa-jira-context.md`) or the request. Write one
line for each behavior that changes, as something you can observe:

- Good: "GET /v1/verify_email returns 404 after the route is removed."
- Bad: "Remove the legacy route." That is the change, not the behavior.

A removal has behaviors too: what now fails or is absent, and what must still
work next to it.

## Step 2: Choose the strongest check that runs here

Go down this list and stop at the first level that can show the behavior in the
sandbox:

| Level | What it observes | Cost here |
|---|---|---|
| `functional` | A user flow in a real browser against the full stack | about 100 s to start the stack once, then 10-40 s per test |
| `check` | A request or command against the running stack, with its real output: `curl` a route, read an email from mail_helper, query MySQL | seconds, after the stack is up |
| `integration` | The auth server in-process with the real database and Redis (`*.in.spec.ts`), also `scripts` and `oauth-api` | 10-25 s |
| `storybook` | How a component renders; run `/fxa-storybook-capture` for screenshots | by hand |
| `unit` | One module's logic | seconds |
| `types` | A removal, rename or signature change compiles everywhere | 2-11 s |
| `ci` | Only CI can run it (see Limits) | none |

- Use a lower level only when every higher one cannot run here or cannot show
  the behavior. Write the reason in `why`.
- Add a `unit` line for each edge case and for the regression test: a test that
  fails if you revert the change. Write a new spec when none exists.
- A UI change: a `functional` or `storybook` line to see it, and `unit` for its
  states.
- A route or API change: a `check` or `integration` line that calls it, and a
  `functional` line when a user flow uses it.

## Step 3: Find the specs and write the checks

Search for existing specs before you plan a new one:

```bash
git grep -ln '<route or symbol>' -- '*.spec.ts' '*.test.tsx' '*.in.spec.ts' 'packages/functional-tests/tests'
```

A `check` is a shell command and a regular expression its output must match.
Useful targets on the stack (see `/etc/vm-agent-guide.md`):

- Auth API on 9000: `curl -s -o /dev/null -w '%{http_code}' localhost:9000/v1/<route>`
- Content and settings through nginx on 3030: `curl -s localhost:3030/<path>`
- Captured email: `curl -s localhost:9001/mail/<address>` (it waits until mail arrives)
- The database: `mysql -u root fxa -e '<select>'`

A check must hit a server that runs your code. The auth server, the content
server and the admin server restart on their own when files change (PM2 watch;
the auth server was seen reloading a route removal within 15 s), and settings
has hot reload. The profile server does not: run `pm2 restart profile` after
you change it. The admin server runs its built copy, so after a source change
also run `npx nx run fxa-admin-server:build` (not verified).

Check that the check can fail: run it once before your change when you can.
A check that passes on the old code proves nothing.

## Step 4: Write the plan

`/workspace/.fxa-test-plan.json` (the `.fxa-` prefix keeps it out of the commit):

```json
{
  "items": [
    { "behavior": "GET /v1/verify_email returns 404", "level": "check",
      "run": "curl -s -o /dev/null -w '%{http_code}' 'localhost:9000/v1/verify_email?uid=x&code=y'",
      "expect": "^404$",
      "why": "observe the removed route on the real server" },
    { "behavior": "sign-in for an existing user still works", "level": "functional",
      "spec": "packages/functional-tests/tests/signin/signIn.spec.ts",
      "grep": "login as an existing user",
      "why": "the verification link path crosses the content server and auth" },
    { "behavior": "the other util routes still answer", "level": "integration",
      "spec": "packages/fxa-auth-server/test/remote/misc_tests.in.spec.ts",
      "why": "covers every util route with the database" },
    { "behavior": "no reference to the removed handler remains", "level": "types",
      "why": "a removed export" },
    { "behavior": "OAuth relier verification links are unchanged", "level": "ci",
      "why": "relier flows need the subscriptions capability manager, off here" }
  ]
}
```

- `spec` is a path from `/workspace`; `new: true` marks one you must write.
- `functional` takes an optional `grep` to pick one test in the spec.
- `check` needs `run` and `expect`. It starts the stack first unless you set
  `"needs_stack": false`. `run` goes to `bash -c`, so quote a URL that has `&`
  or `?`.
- Print the plan in the transcript. In a Slack session it is part of your
  first-turn plan, so the person can change it before you code.

## Step 5: Run it

```bash
bash ~/.claude/skills/fxa-verify/verify.sh --run --plan /workspace/.fxa-test-plan.json
```

It runs, in this order:
1. The planned `unit` and `integration` specs, in the right runner and Jest
   project (`plan` lines).
2. The related specs and lint of every changed file, as a safety net (`net`
   lines).
3. The `check` lines, then the `functional` specs, one at a time. The stack
   starts once, before the first of them.

The verdict marks `ci` lines as `CI`, `storybook` lines as `TODO`, and a
missing spec as `FAIL`. A `net` line with `NOREL` means no spec imports that
file; that is fine only when a `plan` line covers its behavior. The verdict is
also written to `/workspace/.fxa-verify-verdict.txt`.

## Limits here

- These run only in CI; plan them as `ci`: OAuth relier flows through 123done
  (`tests/oauth/*`, `loginHint*`, `relayIntegration`, `smartWindowIntegration`),
  the CMS specs (`tests/cms/*`), payments (`local-payments-next`), and
  payments-next unit tests.
- Up to 3 `functional` specs, run one after another. With the stack up, one
  run with 2 workers used 6.85GB of 7.9GB, so nothing else runs beside them.
- `signIn.spec.ts` "servicesWithEmailVerification RP gets exactly one
  verifyLoginCode email" fails here on main. Pick another test from that spec.
- Never plan a whole suite.

## In the PR body

The testing section lists each plan line with its verdict: what you observed
and how, what CI covers, and why. A reviewer reads this to know what was
proved, so put the observed checks first.
