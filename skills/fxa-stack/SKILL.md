---
name: fxa-stack
description: Start, check, and fix the local FxA stack on the sandbox VM. Use before a functional test, a screenshot, or any check that needs auth, content, or settings running, and when a service is down or erroring.
---

# FxA stack on the VM

The stack is started by `fxa-start` (about 2 minutes). It has no subset flag, so
this skill checks what is up and starts the stack only when a check needs it.
Run the helper from anywhere:

    bash ~/.claude/skills/fxa-stack/stack.sh status        # one line per service
    bash ~/.claude/skills/fxa-stack/stack.sh ensure         # start the stack if auth is down, wait for health
    bash ~/.claude/skills/fxa-stack/stack.sh diagnose       # errored services with their last log lines

## What each check needs

| Check | Needs |
|---|---|
| Unit tests, lint, type-check | nothing (MySQL, Redis, Firestore run at boot) |
| auth-server `*.in.spec.ts` integration tests | nothing from pm2; the tests start their own auth on :9100 |
| Settings pages, sign-in, sign-up, screenshots | `ensure` (auth, inbox, content, nginx, settings, profile) |
| Functional test account cleanup | admin-server on :8095, which `fxa-start` starts |
| OAuth through 123done, `tests/oauth/*` | known to fail on the VM (token exchange needs Stripe/Strapi); leave to CI |
| Payments | not supported on the VM; leave to CI |

## Ports

content 3030 (nginx, which proxies to content on 3031 and settings on 3000),
auth 9000, inbox 9001, profile 1111, settings 3000, 123done 8080, admin 8095,
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
| EADDRINUSE on 3030 | nginx owns 3030; content must run on 3031 from `/tmp/content-pm2.config.js` |
| esbuild, swc, or sass "wrong platform" | run `fxa-start` again; its first step rebuilds the native modules |

## Rules

- Do not use `yarn start` or `_scripts/pm2-all.sh` on the VM: they use stock
  configs that collide with the VM's ports and turn Stripe and CMS back on.
- Do not set `FXA_SANDBOX_IP` inside the VM.
- The stack uses about 5 GB of the 8 GB runner. Stop it with `fxa-start --stop`
  before a heavy unit-test run if memory is tight (`free -m`).
