# Sandbox VM: agent guide

This is the operations manual for an AI agent inside the FxA sandbox VM. The
host sends a fresh copy at every launch, so it matches the controller that
started you. For FxA domain knowledge, read `/workspace/ai/AGENTS.md` if it exists.
Chat sessions do not have it; do not report that it is missing.

## 1. Where you are

- **Machine:** Ubuntu 24.04, 4 vCPU, 16GB RAM. GCE and Tart are ARM64 with a 50GB
  disk; Firecracker is x86-64 with a 60GB disk. Memory is still
  the tight resource: the stack with functional tests ran an 8GB runner out of
  memory, so keep `PLAYWRIGHT_WORKERS=2` and never run a whole suite.
- **Backend:** one of two. The rest of this guide notes where they differ.
  - **GCE** (Slack sessions, most pipeline runs): a `c4a-standard-4` instance.
    `/workspace` is a symlink to a clone in the image, `/home/agent/fxa`,
    pinned to the commit the host chose. `node_modules` is native Linux.
    Google deletes the instance after its run limit (90 minutes for a
    pipeline run, 4 hours for a Slack session).
  - **Tart** (a local VM on the operator's Mac): `/workspace` is the host's
    pool slot, shared into the VM. `node_modules` is bind-mounted from a local
    copy.
- **User:** `agent`. Sudo covers only `systemctl start|stop|restart|status`
  for `mysql`, `redis-server`, `firestore-emulator` and `goaws`, plus
  `sudo tee /etc/hosts`. You need no sudo for `mysql -u root` or `redis-cli`.
- **Network:** an allowlist. You can reach `api.anthropic.com`,
  `statsig.anthropic.com`, `registry.yarnpkg.com`, `registry.npmjs.org`,
  `github.com`, `api.github.com`, `codeload.github.com`,
  `objects.githubusercontent.com`, `playwright.azureedge.net`,
  `cdn.playwright.dev`, `pypi.org`, `files.pythonhosted.org` and
  `channelserver.services.mozilla.com` (the pairing channel). Codex runs also reach `api.openai.com`, `chatgpt.com`
  and `auth.openai.com`. Everything else is refused, including other CDNs,
  private ranges and the metadata server. There is no IPv6.
- **Show the change** with new files included:
  `git add -N . && git diff origin/main -- . ":(exclude).fxa-*"`.
- **Credentials:** none for GitHub, Jira or CircleCI. There is no `gh` and no
  `acli`. The host does every push, PR and comment. When a message links a
  mozilla/fxa CircleCI job or workflow, the host adds its failed tests, the end
  of each failed step's log and Playwright's error context (the page when the
  test failed), fenced as untrusted, to the context or the message. The failed
  tests' traces land in `/workspace/.fxa-ci/<test>/trace.zip`. Read them with
  `bash ~/.claude/skills/fxa-functional-local/trace.sh /workspace/.fxa-ci`: the
  actions with the failed one marked, console errors and failed requests.
- **MCP:** only Slack sessions have it; pipeline runs do not. A session has
  one MCP server, `fxa`, whose tools are named `<connector>__<tool>`. They are
  read-only. A tool that refuses a call says why; do not retry it another way.
  If something should be written (a Jira comment, a reply), tell the person.
  Jira, Slack and Figma links are readable through these tools, not the network:
  `jira__getJiraIssue` and `jira__searchJiraIssuesUsingJql` (the host pins the
  site and scopes JQL to FXA; ask for `fields` such as `summary` and `status`),
  `slack__slack_read_thread` and `slack__slack_read_channel`, and `figma__*`.
  Slack reads only #fxa (`C4D36CAJW`) and #fxa-team (`CLV3KMZ8B`); pass the ID,
  not the name. A permalink `/archives/<C>/p1790355024144359` has
  `channel_id` `<C>` and `message_ts` `1790355024.144359` (a dot before the last 6 digits).
  A Bugzilla bug (`bugzilla.mozilla.org/show_bug.cgi?id=N`, `bugzil.la/N`, "bug N") is
  readable with `bugzilla__get_bugzilla_bug` (`bug_id`: N). It shows public bugs
  only, and it cannot search. A Jira ticket's Bugzilla links can be in its
  description or in `jira__getJiraIssueRemoteIssueLinks`.
  Sentry is readable with `sentry__search_issues`, `sentry__search_errors`,
  `sentry__get_sentry_resource` (`resourceType` issue, event or trace, with a
  `resourceId` such as `FXA-AUTH-39E`) and `sentry__find_projects`. Its answers
  can hold a user's uid and location: use them in the Slack reply, never in the PR.
  Grafana (yardstick) is readable with `grafana__search_dashboards`,
  `grafana__get_dashboard_summary`, `grafana__list_datasources` and
  `grafana__query_prometheus`, among others. It is read-only. The FxA datasources
  are Google Managed Prometheus: quote a metric name that has `/` or `.`, and do
  not use a regex on `__name__`.
- **Firefox source:** cite it as `firefox:<path>:<line>`. It stays outside
  /workspace, so it is never part of the FxA diff.
  - **Firecracker:** `~/firefox` is a full checkout with an artifact build
    (prebuilt C++, local front end). Change JS, CSS, HTML or `.ftl`, then run
    `./mach build faster` (a few seconds, no network). C++ changes cannot be
    built here. Open it on the local stack with
    `FIREFOX_BIN=$HOME/Nightly/firefox yarn firefox` from /workspace. To hand
    the change back, run `git -C ~/firefox diff > /workspace/.fxa-auto-media/firefox.patch`;
    the file is posted to the thread. Nothing is pushed to any Firefox repo.
    The checkout is at the commit `git -C ~/firefox log -1` shows; it cannot
    update from here, so say which commit the patch is against.
  - **GCE, or no `~/firefox`:** read it from a sparse clone, about 10 s:

    ```sh
    git clone -q --depth 1 --filter=blob:none --sparse https://github.com/mozilla-firefox/firefox ~/firefox
    git -C ~/firefox sparse-checkout set services/fxaccounts services/sync
    git -C ~/firefox sparse-checkout add browser/components/preferences  # more, when you need it
    ```

    Search the checked-out folders with `grep -rn`. `git grep` across the
    whole tree downloads every file, so add a folder first.

### Reading code without filling your context

Every tool result stays in your context, and every later step reads the whole
context again. A long session pays for a large result many times: in the week
to 2026-10-03, the longest 10% of sessions used half of all tokens.

- **Explore in a subagent.** For a search that needs more than about three
  greps, or for files you will not edit, use the `fxa-explore` subagent (Agent
  tool). It runs on a faster model and returns a short summary with `file:line`
  references; only that summary stays in your context.
- **Find, then read narrowly.** `git grep -n <symbol>` first, then at most about
  120 lines around the hit with `sed -n A,Bp`. Never `cat` a whole source or
  config file, and do not read the same range twice.
- **Keep command output short.** Pipe long output through `head` or `tail`, and
  for tests use the skills, which print only the failures.

<!-- The host puts guide/session.md or guide/pipeline.md here: sections 2 and 3. -->

## 4. What the host refuses to ship

Before it ships anything, the host checks the change. It refuses when:

- The change touches `.github/`, `.circleci/`, `.husky/`, `_scripts/`,
  lint-staged config, `.yarnrc*`, `.yarn/`, `.npmrc`, or the `scripts`,
  `lint-staged` or `husky` keys of any `package.json`. A dependency bump is
  allowed. If the ticket really needs a tooling change, say so in the PR body;
  the operator can relaunch with permission.
- `origin/main`'s `_scripts/check-frozen.ts` rejects a path. Read that file
  before you edit near a frozen path.
- A conflict marker is left in a file.

Scratch files whose names start with `.fxa-` at the root of `/workspace` are
never committed. Any other new file is.

## 5. Verify your change

Before you change code, write a test plan with `/fxa-test-plan`: each behavior
the ticket changes and how you will see it work, the way a user or client
would: a functional flow, a check against the running stack, or an integration
spec, with unit tests on top for edge cases. Save it in
`/workspace/.fxa-test-plan.json`. Then
use `/fxa-verify --run --plan /workspace/.fxa-test-plan.json`. It runs the
planned tests, then the related specs and lint for each changed package, and
only for the files you changed. With no file paths it also
checks changes an earlier run left on the slot, so read `git status` first.
After a fix, rerun only what failed with `/fxa-verify --failed`. Run the full
`--run` once more before the handoff.
When a run fails and its output or log is long, give the path to the
`fxa-log-triage` subagent and read its summary, not the log.

- Never run a whole package suite. The whole auth unit project (4157 tests)
  left 0.2GB free with Jest's default 3 workers and the stack off, 0.5GB with
  `--maxWorkers=2`; with the stack up it runs the machine out of memory. Pass
  `--maxWorkers=2` when you run more than a few auth specs by hand
  (`/fxa-verify` does). Do not run two auth integration suites at once.
- Auth unit tests need `SNS_TOPIC_ENDPOINT` unset (`env -u
  SNS_TOPIC_ENDPOINT yarn test <spec>`): `/etc/agent-env.sh` sets it for the
  goaws stub, and `config/index.spec.ts` rejects it. `/fxa-verify` does this.
- `nx test-unit fxa-settings` runs no tests: it only prints "No unit tests
  present". The real command, from `packages/fxa-settings`, is
  `CI=true SKIP_PREFLIGHT_CHECK=true node scripts/test.js --watchAll=false --findRelatedTests <files>`.
  Without `CI=true` it starts in watch mode and never ends.
- Lint is `npx eslint <files>` from the package, which `/fxa-verify` runs in
  a second or two. `npx nx lint <package>` works too, but is slower: for
  auth, content and shared it first installs `glean_parser` from PyPI.
- For a removal, a rename or a changed signature, also type-check.
  `/fxa-verify --run` does it by default (`--no-types` skips it). By hand: `npx tsc --noEmit` in the package
  (auth: `-p tsconfig.build.json`, 11 s and 2.5GB; a lib:
  `-p tsconfig.lib.json`, about 1 s).
- One auth test: `yarn test <spec> -t "<name>" --verbose` from
  `packages/fxa-auth-server`.
- Never run `nx reset`. It destroys the cache and slows every later step.
- If lint or a unit suite runs longer than 10 minutes, stop it and say in your
  handoff that CI covers it. CI runs lint and the full suite anyway. This does
  not apply to a functional test the engineer asked for.
- Keep each wait under 4.5 minutes. After 5 idle minutes the prompt cache
  expires, and your next call writes it again: about $0.40 each time in a long
  session. Run a command that ends sooner in the foreground. Start a longer one
  in the background, then wait in steps of `timeout 270`. A Bash call stops at
  10 minutes in any case.
- For a functional run that can take longer, use
  `run.sh --bg <spec> [filter]`, then `run.sh wait` until it gives the result
  (see `/fxa-functional-local`). `wait` returns at once when the run ends or
  dies. Keep waiting in the same turn: the session pauses when it is idle.
- Never write your own wait loop, such as `until grep -q DONE out; do sleep 5; done`.
  It does not see the job die, so it waits until the 10-minute timeout. A hook
  blocks it, and a `sleep` of 30 s or more.
- Bracket the first letter in `pkill -f '[p]attern'`, and run the pkill in a Bash call
  of its own. A bare pattern, or a command that also names the process (`&& node
  serve.js`), matches your own shell, and the call kills itself (exit 144). A hook blocks it.
- Before the handoff, run `/fxa-unslop`. It checks your tests, leftovers,
  comments and PR body against what reviewers flag most often.

## 6. The local FxA stack

Infrastructure starts at boot: MySQL 3306, Redis 6379, Firestore emulator
9090, goaws (SNS and SQS stub) 4100. The `fxa` database has no tables until
the patcher runs: `fxa-start` runs it, and so does `/fxa-verify` before an auth
integration test. By hand: `node packages/db-migrations/bin/patcher.mjs`
(about 8 s). Without it, auth integration tests wait 63 s and fail on
`ER_NO_SUCH_TABLE`; `REMOTE_TEST_LOGS=true` shows that error. Check them with `mysql -u root -e 'SELECT 1'`,
`redis-cli ping`, and `ss -ltn | grep -E ':(9090|4100) '`. goaws answers
`GET /` with 400, so `curl -f` reports it as down when it is up.

The FxA services do not start on their own. Start them only when you need
them: in a pipeline run, only when your test plan names a functional spec.

```bash
fxa-start            # builds the admin server, starts everything (about 100 s)
fxa-start --status   # PM2 process list
fxa-start --stop     # stop the services and nginx
```

| Service | Port | Check |
|---|---|---|
| Auth server | 9000 | `curl -sf localhost:9000/__heartbeat__` |
| nginx (content, settings) | 3030 | `curl -sf localhost:3030/` |
| Content server | 3031 | behind nginx |
| Settings dev server | 3000 | `curl -sf localhost:3000/` |
| Profile server | 1111 | `curl -sf localhost:1111/__heartbeat__` |
| 123done (test relying party) | 8080 (nginx) to 8081 | `curl -sf localhost:8080/` |
| Admin server (test cleanup uses it) | 8095 | `ss -ltn \| grep ':8095 '`; PM2 app `admin-server` |
| mail_helper (captured email) | 9001 | `curl -s localhost:9001/mail/<address>` waits until mail arrives |
| Cloud Tasks emulator | 8123 | `pm2 describe cloud-tasks-emulator` |

The stack uses about 2.8GB: `settings-react` alone is 1.2GB. Logs are in
`~/.pm2/logs/<name>-out.log` and `-error.log`, or `pm2 logs <name> --lines 50
--nostream`.

What is different from production:

- Stripe and subscriptions are off, the CMS is off, and rate limiting is off
  (`CUSTOMS_SERVER_URL=none`).
- The auth server's `PUBLIC_URL` must stay `http://localhost:9000`. The JWT
  issuer comes from it, and any other value breaks OAuth.
- The Cloud Tasks emulator must run before the auth server, or
  `accountDestroy` returns 500. `fxa-start` does it in that order.
- Settings has hot reload: an edit to `.tsx`, `.css` or `.ftl` shows at once.
  The content server restarts when its `.js`, `.html` or `.json` files change;
  refresh the browser.
- nginx on 3030 sends settings assets and HMR (`/static/`, `/settings/static/`,
  `/ws`, locales, `legal-docs`, `assets`) to 3000, and everything else to 3031.
- On Tart only, `fxa-start` first installs Linux builds of the native modules,
  because the shared `node_modules` come from macOS.

## 7. Functional tests

Use `/fxa-functional-local` for one spec. It starts the stack if needed,
records a video, and its `--bg` and `wait` handle a run longer than 10 minutes.

- While you change one test, give `run.sh` the test title as its filter. A
  whole spec file took 51 s on average, and most hand runs ran the whole file.
- Run `npx playwright test` by hand only for more than one spec or project.
  Start it with `run_in_background`, then wait with
  `timeout 270 tail --pid=<pid> -f /dev/null`, again until it ends.
- The projects are `local` (Firefox), `local-chromium` and
  `local-payments-next`. There is no `sandbox` project.
- The config defaults to 4 workers. Set `PLAYWRIGHT_WORKERS=2`: with the stack
  up, 2 workers peaked at 6.85GB of 7.9GB. Stop other jobs first.
- A failed test keeps a trace in
  `/workspace/artifacts/functional/<test>/trace.zip`.
- Checked on main on 2026-09-27: `signIn.spec.ts` "servicesWithEmailVerification
  RP gets exactly one verifyLoginCode email" fails here in its cleanup
  ("Failed to cleanup account ... Incorrect password"). Treat it as a local
  failure, not your change, unless you touched that flow.
- Do not set `FXA_SANDBOX_IP` in the VM. Tests use `localhost`.
- The stack sets `GEODB_LOCATION_OVERRIDE` as CI does (US, postal code 85001),
  so every request resolves there and no city is shown. A spec that expects a
  city cannot pass on CI. CI's other test settings are in the functional-tests
  job's `environment` in `.circleci/config.yml`; check it when a spec depends on a flag.
- OAuth relier flows through 123done (`tests/oauth/*`, `loginHint*`,
  `relayIntegration`, `smartWindowIntegration`) can run here: the host ships
  `packages/123done/secrets.json` and restarts 123done. If a token exchange
  fails with errno 109, the secret is missing; say so in your handoff or reply. If one
  fails on a subscriptions capability, CI covers it.
- These specs cannot pass here, and CI covers them: the CMS specs
  (`tests/cms/*`) and payments (`local-payments-next`). Verify with direct
  content-server flows (sign-in, sign-up, reset, settings) or Sync through
  `/pair`, and say in the handoff what CI must cover.

## 8. Screenshots and videos

Save them in `/workspace/.fxa-auto-media/` as `.png`, `.jpg`, `.webp`, `.gif`,
`.webm`, `.mp4` or `.mov`, or a `.patch` or `.diff`. Each must be a plain file inside the workspace, not
a symlink, at most 100MB. A pipeline PR attaches only the image and video
types. In a Slack session, a file must be under 20MB and
have a name of only letters, digits, `.`, `_` and `-`; a `.mov` is not posted. For a component with a sibling `*.stories.tsx`, use
`/fxa-storybook-capture`. For a live page (a route, a signed-in state, a
viewport, a locale or dark mode), or to check a recorded video frame by frame,
use `/fxa-page-shot`; do not write a throwaway Playwright script or spec. If you cannot take a screenshot you planned, write
the reason to `/workspace/.fxa-auto-media-skipped.txt`.

## 9. Skills you have

Plugins do not load here. These skills are copied in at launch:
`/fxa-verify`, `/fxa-functional-local`, `/fxa-stack`,
`/fxa-storybook-capture`, `/fxa-vm-selfcheck`, `/fxa-vm-handoff`,
`/fxa-test-plan`, `/fxa-unslop`, `/code-simplifier`, `/ponytail-review`,
`/create-pr-description`, `/humanizer`, `/pr-review-typescript`,
`/quick-review`, `/fxa-save-investigation`, `/fxa-page-shot`, `/fxa-jira-link` and
`/fxa-perf` (page speed: builds, timed cold loads, side-by-side video).

Subagents (Agent tool) run on a smaller model with a small context of their own,
so their work does not fill yours: `fxa-explore` (searching, above),
`fxa-reviewer` (the wrap-up review), `fxa-writer` (the PR title and body) and
`fxa-log-triage` (a failed run's log: give it the path, read its summary). `/fxa-vm-selfcheck`
starts with `check.sh`, which does its mechanical checks in one call.

The FxA repo adds its own in
`/workspace/.claude/skills`, such as `/fxa-review-quick`, and its rules in
`/workspace/.claude/rules/`. For FxA code, the repo's rules and skills win.

These repo skills need what the sandbox lacks (`gh`, `git push`, CircleCI,
Jira or Confluence writes, other MCP servers), so the settings block them:
`/fxa-pr-open`, `/fxa-pr-status`, `/fxa-pr-debug`, `/fxa-run-functional-tests`,
`/fxa-dot-release`, `/fxa-issue-verification`, `/fxa-ai-fixme-create-issue`,
`/fxa-changelog`, `/fxa-docs-sync`, `/fxa-dep-triage` and `/fxa-triage`. Do
not offer them. To record proof, use `/fxa-functional-local` and the media
folder. `/fxa-jira-bug-description` and `/fxa-jira-feature-description` can
draft a ticket, but not file it.

## 10. When something goes wrong

```bash
systemctl status agent-init; journalctl -u agent-init --no-pager | tail -50
pm2 status; pm2 logs --lines 50 --nostream
free -m; df -h /home/agent
```

- A refused network call means the host is not on the allowlist. Do not look
  for a way around it; say in the handoff what you could not fetch.
- If you run out of memory, stop the services you do not need
  (`fxa-start --stop`) and run fewer tests at once.
- If you are cut off mid-task, your changes stay in `/workspace`. The operator
  relaunches on the same slot, and the new run continues from your tree.
