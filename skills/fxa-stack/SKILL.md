---
name: fxa-stack
description: Start, check, and fix the local FxA stack on the sandbox VM. Use before a functional test, a screenshot, or any check that needs auth, content, or settings running, and when a service is down or erroring.
---

# FxA stack on the VM

The stack is started by `fxa-start` (about 2 minutes). It has no subset flag, so
this skill checks what is up and starts the stack only when a check needs it.
Run the helper from anywhere:

    bash ~/.claude/skills/fxa-stack/stack.sh status        # one line per service
    bash ~/.claude/skills/fxa-stack/stack.sh ensure         # start the stack if auth, content, or settings is down, wait for health
    bash ~/.claude/skills/fxa-stack/stack.sh diagnose       # errored services with their last log lines
    bash ~/.claude/skills/fxa-stack/stack.sh account 2fa    # a test account, as one line of JSON
    bash ~/.claude/skills/fxa-stack/stack.sh restart auth KEY=VAL   # one service with extra env
    bash ~/.claude/skills/fxa-stack/stack.sh wait auth settings     # block until healthy (3 min each)
    bash ~/.claude/skills/fxa-stack/stack.sh strapi         # local Strapi CMS on :1337, CMS on in auth and content

Use `wait` after a change that restarts a service, not a `sleep` or `curl`
loop. Never run `fxa-start` yourself: `ensure` runs it only when the core is
down, and a second copy fails with nginx EADDRINUSE on 3030 and 8080.

## Test accounts

`account verified|unverified|2fa` creates an account on the local auth server
with `fxa-auth-client`, the client that the functional tests use. It prints one
line of JSON:

    {"email":"stack-<hex>@restmail.net","password":"stack-test-password","uid":"...","sessionToken":"...","verified":true}

- `verified`: a verified account and a verified session (`preVerified`).
- `unverified`: the email is not verified, so the session is not verified.
- `2fa`: a verified account with TOTP on. The JSON adds `totpSecret` (base32).
  Any TOTP tool, or `otplib` in `/workspace`, computes codes from it.

Auth must be up (`ensure`). The script does not delete the account.

## Restart one service with extra env

`restart <pm2 name> [KEY=VAL...]` finds the pm2 config that defines the
service (a `/tmp/*-pm2.config.js` wrapper from `fxa-start` first, then
`packages/*/pm2.config.js`), adds each `KEY=VAL` to its `env`, and starts it
again. It then waits up to 2 minutes for the health check of that service.
With no `KEY=VAL`, the service goes back to the env of its config.

    bash ~/.claude/skills/fxa-stack/stack.sh restart auth SIGNIN_CONFIRMATION_ENABLED=false
    bash ~/.claude/skills/fxa-stack/stack.sh restart auth     # undo the override

The names are pm2 names: `auth`, `inbox`, `content`, `settings-react`,
`profile`, `123done`.

## CMS (Strapi)

CMS is off in the stack by default. `strapi` turns it on for this session:

1. It runs `mozilla/fxa-strapi` (branch `dev`) from `/home/agent/fxa-strapi` on :1337. It
   clones and builds it first when the image does not have it (about 1.5 minutes).
2. It adds or updates each Relying Party in `strapi-seed.json` (next to the script) and
   publishes it. The default seed is the content that `tests/cms/*.spec.ts` expects:
   123done (`entrypoint=purple`) and Sync (`entrypoint=firefox-cms`).
3. It restarts auth and content with CMS on and cache TTLs of 1 s.

To try a style, use one of these:
- Edit `strapi-seed.json` or a copy (`strapi my-seed.json`), and run `strapi` again.
- Edit the entry in the admin at http://127.0.0.1:1337/admin, and publish it.

Then load the page again with its `entrypoint`, for example
`http://localhost:8080/?entrypoint=purple`. `strapi off` stops Strapi and turns CMS off.

### Run the CMS functional tests

    bash ~/.claude/skills/fxa-stack/stack.sh strapi
    cd /workspace/packages/functional-tests
    PLAYWRIGHT_WORKERS=2 npx playwright test --project=local tests/cms
    bash ~/.claude/skills/fxa-stack/stack.sh strapi off

Without `strapi`, every spec skips, and a skip proves nothing. The specs check
the headline, the description, the logo and the button color of each page, so a
change to `strapi-seed.json` can break them. Keep the default seed as it is, and
use a copy for a new style.

### How CMS works here

- auth reads each Relying Party from Strapi's GraphQL API with a `clientId` and an
  `entrypoint`, and `GET /v1/cms/config?clientId=..&entrypoint=..` returns it. `{}`
  means no entry (or CMS is off). Settings then shows the default page.
- auth makes its CMS clients only when a Stripe key is set, so `strapi` gives it a
  dummy key. If `/v1/cms/config` returns `{}` for a seeded entry, look for
  `cms.getConfig` in `pm2 logs auth`.
- Use `127.0.0.1:1337`, not `localhost:1337`: Strapi listens on IPv4 only.
- The admin at http://127.0.0.1:1337/admin asks you to make an admin user the first time.
- The 2FA specs in `tests/cms` need recovery phone, so `strapi` turns it on.

### The fxa-strapi project

`mozilla/fxa-strapi` holds the Strapi config and the content schema, not the
content: the real content lives in the cloud instances, so the local database
has only what `strapi` seeds.

- **Clone:** `/home/agent/fxa-strapi`, branch `dev`. The `dev`, `stg` and `prod`
  branches deploy on push to their environments. It is not one of the team's repos
  yet, so a session cannot open a PR there: hand back a diff.
- **Stack:** Strapi 5, npm (not yarn), SQLite in `.tmp/data.db`, a local `.env` that
  `strapi` writes with random keys. Delete `.tmp/data.db` to start empty.
- **Install:** use `npx -y npm@10.9.2 ci`, not `npm ci`: npm 11 rejects the lockfile.
  One dependency is a `git+ssh` URL, so set the https rewrite as `stack.sh` does.
  `package.json` asks for Node 20 or lower; it runs on the runner's Node.
- **Layout:**
  - `src/api/<type>/content-types/<type>/schema.json`: one content type each.
    FxA account pages use `relying-party`; the rest are subscription types.
  - `src/components/accounts/*.json`: the parts of a Relying Party, such as
    `shared` (colors, logos) and `page-config` (headline, description, button text).
  - `src/index.js`: at boot it makes the local full-access API token and seeds
    a meter. The error `bootstrap failed: windowPeriod is required` is from the
    meter seed and does no harm.
- **Required on a Relying Party:** `shared`, `EmailFirstPage`, `SignupSetPasswordPage`,
  `SignupConfirmCodePage` and `SigninPage`. Entries use draft and publish, so FxA
  sees an entry only after it is published (`strapi` publishes the seed).
- **A schema change** (a new field on a page, say) needs three steps:
  1. Edit the `schema.json` or component file, then run `npm run build` and
     `pm2 restart strapi`.
  2. In fxa, add the field to `libs/shared/cms/src/lib/queries/relying-party/query.ts`,
     and run `nx run shared-cms:codegen` with `STRAPI_CLIENT_CONFIG__GRAPHQL_API_URI=http://127.0.0.1:1337/graphql`
     and `STRAPI_CLIENT_CONFIG__API_KEY` set to the token in `src/index.js`.
  3. Use the field in Settings, and add it to a copy of the seed to see it.
  These steps were not yet tried on the runner; say in the handoff what you checked.
The recovery phone spec still fails here, because the stack has no Twilio test credentials and sends no SMS.

## What each check needs

| Check | Needs |
|---|---|
| Unit tests, lint, type-check | nothing (MySQL, Redis, Firestore run at boot) |
| auth-server `*.in.spec.ts` integration tests | nothing from pm2; the tests start their own auth on :9100 |
| Settings pages, sign-in, sign-up, screenshots | `ensure` (auth, inbox, content, nginx, settings, profile) |
| Functional test account cleanup | admin-server on :8095, which `fxa-start` starts |
| OAuth through 123done and 321done, `tests/oauth/*` | `ensure`, which also starts 321done (:10139) when it is down |
| CMS specs, `tests/cms/*`, a CMS-styled page | `strapi`, then the specs (see "CMS (Strapi)"); `strapi off` after |
| Payments | not supported on the VM; leave to CI |

## Ports

content 3030 (nginx, which proxies to content on 3031 and settings on 3000),
auth 9000, inbox 9001, profile 1111, settings 3000, 123done 8080, 321done 10139, admin 8095,
MySQL 3306, Redis 6379, Firestore 9090, goaws 4100, Cloud Tasks 8123.

## Fixes for common failures

| Symptom | Fix |
|---|---|
| A service shows `errored` | `pm2 logs <name> --lines 50 --nostream`, fix the cause, `pm2 restart <name>` |
| auth: `Cannot find module './errors'` right after boot | `pm2 restart auth` |
| auth or content: missing `auth.ftl` or `dist/libs/shared/l10n` | `yarn l10n:clone && npx nx build fxa-auth-server` (or `npx nx build shared-l10n`) |
| `accountDestroy` returns 500 | Cloud Tasks emulator missing: `pm2 restart cloud-tasks-emulator && pm2 restart auth` |
| Unknown table or column | `cd /workspace && node packages/db-migrations/bin/patcher.mjs` |
| goaws-stub crash-looping on :4100 | real goaws is up: `pm2 delete goaws-stub` |
| Pairing or a Desktop Sync sign-in fails: `/v1/oauth/token` 500 (errno 998), Firefox says `No keyFetchToken` | no CMS, so no CapabilityManager for JWT tokens; an image from before 2026-10-07 lacks the fix: `stack.sh restart auth JWT_ACCESS_TOKENS_ENABLED=false` |
| EADDRINUSE on 3030 | nginx owns 3030; content must run on 3031 from `/tmp/content-pm2.config.js` |
| esbuild, swc, or sass "wrong platform" | run `fxa-start` again; its first step rebuilds the native modules |

## Rules

- Never run `pm2 restart --update-env`. It copies your whole shell env, for
  example `NODE_ENV`, into the service and can break it. Use `stack.sh restart`.
- Do not use `yarn start` or `_scripts/pm2-all.sh` on the VM: they use stock
  configs that collide with the VM's ports and turn Stripe and CMS back on.
- Do not set `FXA_SANDBOX_IP` inside the VM.
- The stack uses about 5 GB of the 16 GB runner. Stop it with `fxa-start --stop`
  before a heavy unit-test run if memory is tight (`free -m`).
