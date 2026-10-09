# Monitor

This session works on Mozilla Monitor (`mozilla/blurts-server`), a Next.js app. The FxA guide above describes the FxA stack, which runs beside Monitor so that sign-in works. For your own work, this part replaces the FxA commands above: do not run `fxa-start`, FxA tests or FxA checks unless the task is about sign-in.

## Setup

The host sets Monitor up in the background when the session starts. It takes about 2 minutes.

- Before you run anything, check that `/home/agent/.profile-ready` exists. If it does not, wait, and read the progress in `/var/log/profile-boot.log`.
- If `/home/agent/.profile-failed` exists, it says what failed. Tell the person, and do not try to install things yourself.

## Commands

Run every Monitor command in `/workspace` with Node 20 first on the path, and without FxA's `NODE_ENV`. The global Node is 24, and Monitor needs 20. The shell exports `NODE_ENV=development` for FxA, which makes Monitor's config tests fail:

```
export PATH=/opt/node20/bin:$PATH; unset NODE_ENV
```

| Task | Command | Time |
|---|---|---|
| Unit tests | `npm run test` | about 50 s |
| Integration tests | `npm run test-integrations` | about 10 s |
| Lint, types and Nimbus check | `npm run lint` | about 35 s |
| One test file | `npx vitest run <path>` | |

## The running app

- The dev server runs on http://localhost:6060. Its log is `/home/agent/.monitor-dev.log`.
- To restart it, run `pkill -u agent -f next-server; pkill -u agent -f 'next dev'`, then `cd /workspace && nohup setsid npm run dev > /home/agent/.monitor-dev.log 2>&1 < /dev/null &`. Start it fully detached, or your shell hangs.
- The database is Postgres: `postgres://blurts:blurts@localhost:5432/blurts`, and `test-blurts` for tests.
- HIBP, Redis, Sentry and email use local mocks or are off. Do not call real services.

## Signing in

Monitor signs in through the local FxA stack:

- FxA is at http://localhost:3030.
- Use a new email such as `monitor-test-<n>@restmail.net`, and a password that does not contain the email's local part.
- The sign-up code is in the `x-verify-short-code` header of http://localhost:9001/mail/<local-part>.
- After sign-in, the browser lands on `/en/user/dashboard`.

## Rules for this repo

- CI is GitHub Actions. Do not edit `.github/`.
- `.env.local` holds local secrets. Never print it or commit it.
- This profile is read-only: the host ships nothing from this session. Show your change with the diff, and with test output or a screenshot.
