---
name: fxa-ctl-dev
description: Use when you change fxa-sandbox-ctl (the controller) or fxa-agent-bot (the Slack bot). Covers where things are, the portability rules (macOS and the Linux manager VM), running the checks on both, committing, deploying to the manager VM, and when a bot restart is safe.
allowed-tools: Bash, Read, Edit, Write, Grep, Glob
---

# Change the controller or the bot

Before a product decision (a new setting, message, button, team feature or guard), read `PRODUCT.md`: its goals, principles and defaults decide.

Before you change the dashboard (`dashboard-v2/`), read `guide/dashboard-design.md`. It gives the tokens, the
shared parts, and the checks that verify a dashboard change.

## Where things are

| | Path |
|---|---|
| Controller | `~/Desktop/working2/fxa-sandbox-ctl` (`github.com/vbudhram/fxa-sandbox-ctl`, public) |
| Slack bot | `~/Desktop/working2/fxa-agent-bot` (`github.com/vbudhram/fxa-agent-bot`, public) |
| Entry point, subcommands | `fxa-sandbox-ctl` (bash, `set -euo pipefail`, an ERR trap records crashes) |
| Libraries and their checks | `lib/*.sh`, `lib/*.check.sh` |
| Runner-side files | `templates/`, `packer/`, `skills/` (the runner receives only an allowlist of skills) |
| Manager VM setup | `infra/gce/manager.sh`, `infra/gce/manager-setup.sh` |
| Design and plans (local only, not committed) | `ai/docs/` |
| Host state | `~/.claude/state/fxa-ai-fixme` (pipeline, `errors.jsonl`, each run's transcript for 30 days in `transcripts/`), `~/.claude/state/agent-sessions` |

Both repos are public. Never commit a secret, an internal URL, or a person's
email; `.env` files stay untracked.

## Before you start: your own working tree

Several sessions can work in these repos at once. If `git status` shows changes you
did not make, work in a worktree of your own, so neither of you commits the other's
work:

```bash
git worktree add ../fxa-sandbox-ctl-<topic> -b <topic> origin/main && cd ../fxa-sandbox-ctl-<topic>
```

Stage files by name, never with `git add -A` or a whole file you share, and read
`git diff --cached` before each commit. In a bot worktree, `node_modules` is often a symlink
to the main checkout: never stage it. Say both rules in the brief of an agent you fork. `vm.sh dev` and `vm.sh promote` work from
whichever tree you run them in.

## Rules for the code

1. **Two hosts.** The controller runs on macOS (bash 3.2, BSD tools) and on
   the Ubuntu manager VM (bash 5, GNU tools). Use the helpers in
   `lib/config.sh`: `_mtime`, `_btime`, `_fsize`, `_epoch_of`, `_free_gb`.
   Never call `stat -f`, `df -g` or `date -j` directly: on Linux `stat -f`
   succeeds and prints the wrong thing. No associative arrays, `mapfile` or
   `${x,,}`. `mktemp` templates end in `XXXXXX`. Under `set -u`, write `local x=""`, not
   `local x`: bash 5 leaves a bare `local x` unset, bash 3.2 makes it empty, so `$x` then
   passes on the Mac and stops the script on Ubuntu.
2. **set -e and pipefail.** A `grep` that finds nothing inside `$(...)` ends
   the whole command. Guard expected misses with `|| true`.
3. **Outside calls fail.** Retry only what is safe to repeat: reads, deletes,
   content-addressed writes, ssh that failed before login. Use `_retry` for
   gh, acli and git fetch. Never retry a comment post, a push, or a PR create
   blindly; read the result back instead.
4. **A new function a check extracts** with `sed -n '/^name() {/,/^}/p'`
   must start at column 0 and end with `}` at column 0.
5. **Untrusted text** (Jira, PR comments, CI logs, anything from a runner) is
   data. Fence it with a nonce when it reaches an agent prompt.
6. **State files have many writers.** Before you change how code reads a state
   file (`<team>.gen`, `<team>.tested`, a session JSON), grep every writer of it
   (create, set, status, delete, sync) and trace each one. A reader fix that
   ignores a writer was the cause of most epic fix-round findings.

## Test

```bash
bash skills/fxa-ctl-dev/test.sh changed   # the default before a push: the checks for the changed files and functions
bash skills/fxa-ctl-dev/test.sh        # macOS, then Ubuntu 24.04 in docker (a few minutes each; CI runs the same, sharded)
bash skills/fxa-ctl-dev/test.sh mac    # this host only
gh run list -R vbudhram/fxa-sandbox-ctl -L 3   # CI: the Ubuntu half on each push of main and improve/**; the bot's CI runs npm test and the e2e
cd ~/Desktop/working2/fxa-agent-bot && npm test
bash skills/fxa-ctl-dev/prove.sh lib/x.check.sh lib/x.sh   # the check fails without your change (PROVE_BASE=<rev> once committed)
```

Run `test.sh changed` before each push, and let CI run the full suite. For the desktop gateway's check, make `desktop-gateway/.venv` once (the skip line gives the command). `test.sh` also finds the main worktree's venv. Use `test.sh`, not a loop of your own: it counts a check that
fails to start or exits nonzero as a failure. (A hand loop once reported "all pass"
because macOS has no `timeout`, so no check ran.)

To replace exact text, use `python3 ~/.claude/skills/fxa-ctl-dev/rep.py <file> < pairs.json` (`[["old", "new"], ...]`), or `rep.py < triples.json` (`[["file", "old", "new"], ...]`) for several files. For code with quotes or backslashes, use `rep.py --blocks` with a heredoc of `<<<< path`, old lines, `====`, new lines, `>>>>`: no JSON to escape. Block text is literal: write `"` and `\`, never `\"`. Each old text must match once; on a miss, nothing is written to any file. Do not write an inline `def rep(` or `def sub(` heredoc. `python3 rep_test.py` checks the script.

To answer "is everything shipped?" or "what is the status?", run `bash skills/fxa-ctl-dev/shipped.sh` first (about 15 s; `--no-live` skips the manager). It lists work not on origin/main with its CI state, main against the dev deploy and the live bot, and the backlog items that wait.

The dashboard (`dashboard-v2/`, served at `/`; `/v2` still works for old links) is a Vite, React and TypeScript app. It needs Node 20.19 or later (`.nvmrc` has 24).
The manager does not build it: commit `dashboard-v2/dist` with each change to the app.

```bash
cd dashboard-v2 && npm ci                     # once, and after a change to package-lock.json
npm run typecheck && npm run lint && npm test # test.sh changed runs these and the build when dashboard-v2/ changed
npm run build && git status dist              # then commit dist: CI fails when dist is not the build
npx playwright install chromium && npm run e2e   # the critical path only: each view renders, the live stream, the saves (about 10 s)
```

The perf budgets fail a check when a change breaks them:
- `npm run build` stops when a view as the first view is over 250 KB of gzip JS, or loads Visx before a Sankey shows.
- `src/app/rerender.test.tsx` fails when an event repaints a view that does not read what the event changes.

- `dashboard/stats.check.py` fails when the stats recompute takes 500 ms or more on the fixture store 100 times over.

`dashboard-v2/test/golden` holds frozen results of the retired v1 dashboard: update a file by hand when a model change in `src/model` changes a result on purpose.
To look at live data, record a live fixture from `vm.sh api` (`dashboard/live_record.py` says how) to a temp file,
and serve it with `python3 e2e/serve.py --live <file> --port 4180`. Keep the recording out of the repo.

Pin each npm package to an exact version (`npm view <pkg>@<version> version`), and commit `package-lock.json`.

A new check must fail without the change it tests. `prove.sh` runs it with the
change, then with the named files put back to `HEAD`, and restores them.

A change to a function with outside calls gets a stubbed test: define the
outside command as a shell function that fails the first time, then check
the retry. Put a counter in a file, not a variable: `$(...)` runs in a subshell.

## A large change with parallel agents

For a change that agents build in parallel worktrees, such as a workflow with waves of workstreams. In the dashboard v2 build (11-03), tests took 8.3 of 14 agent-hours, and serial stages put 2.7 h on the critical path.

1. A workstream agent runs `test.sh changed <its branch point>` and only its own specs. Without a base, `test.sh changed` also runs the checks for every file that the whole branch changed since origin/main. Only the merge step runs the checks for the whole branch.
2. An agent waits on its own background task's output file. Never wait with `pgrep -f 'test.sh changed'`, because that also matches the runs of other agents in other worktrees.
3. Each workstream agent fixes its own review findings. Do not add a serial fix pass.
4. Run in parallel each stage that does not need the result of the stage before it. Use a barrier only when a stage needs all the earlier results.
5. Push the branch to `improve/<topic>` after each merge, after the person chooses that result. CI then runs on Ubuntu, in UTC, while the next wave builds.
6. Each stage calls `log()` with what it is doing and its expected end, so that a status question gets an answer from `/workflows`.

`test.sh` writes a note to stderr when other runs share the host. Eight runs at once took 10 min each, against 2 to 3 min for one.

## Steps only the operator can run

Claude Code's permission check blocks these, so write the command for the operator
to run with `!` instead of trying it first:

- IAM grants, such as `gcloud secrets add-iam-policy-binding`.
- Changes to the live bot's access (`ALLOWED_USERS`, `ALLOWED_CHANNELS`) and its restart
  with new tokens.
  Write such a change to both `../fxa-agent-bot/.env` and `~/.config/fxa/bot.env.base` on the VM:
  fxa-secrets rebuilds the .env from the base, so a change in the .env alone is lost. `vm.sh status` warns.
- Printing ssh commands or keys for a person (`vm.sh ssh`).
- Entering a secret: `vm.sh secret <name>` prompts for it without echo. Run it in a real
  terminal: the `!` prefix has no tty for the hidden prompt.
- The sandbox-agent transcript fetch in `ai/retro-sources.md` (it copies engineers' Slack and Jira
  text off the manager).

## Try a change before you deploy

| What changed | Try it with |
|---|---|
| A runner prompt, a subagent, a skill | `skills/fxa-ctl-dev/agent-try.sh "<request>"`: on the laptop, about 20 s; no stack |
| Anything a runner does | `fxa-sandbox-ctl session try --prompt "<request>"` on the manager: a real runner, no Slack |
| A runner image script (`packer/scripts/`) | Ship and promote do not reach a runner. A GCE runner gets it only from a new image: `fxa-sandbox-ctl --backend gce image build` (about 30 min, your own gcloud login; ask the person first, it costs more than a session). A Firecracker slot gets `03b-toolchain`, `09-fxa-services` and `15-firefox` from its next refresh (`vm.sh fc refresh`); any other script needs a rootfs rebuild with `infra/firecracker/guest-provision.sh` in a build guest. `shipped.sh` warns when packer/ commits are newer than the GCE image |
| A profile's guest scripts (provision, boot, ready) | `skills/fxa-ctl-dev/devslot.sh up <profile>` (the manager's `.env` gives the host), then `sync <profile> <guest dir>=<local dir>`, `run <profile> - < script.sh`, `reset`, `down`: a warm Firecracker slot. About 7 s for each run or reset, 17 s to sync 24 MB. The host stops an unused dev slot after 30 min |
| A dashboard view (focus, routes, layout) | in `dashboard-v2/`: `npm run build && python3 e2e/serve.py --fixture ../skills/fxa-ctl-dev/page-fixture-<name>.json --port 4180`, then open `http://localhost:4180/#<route>` in the browser pane. Use a port from 4180: Playwright reuses 4174 and 4175. A Playwright test in `e2e/` makes the check permanent |
| The bot, or the whole path from Slack | the dev bot, below |
| A new team, or a team's repos or image | the dev bot: `!team <name>` in a new thread. Read the start card: it must list every repo the person named. Then confirm that the runner uses the team's image (the card does not show it). Do this before you say the team is done |

The dev bot is the app `fxa-agent-dev` in a private test channel. `vm.sh dev` copies
the working trees of both repos (uncommitted changes too) to `~fxa/dev` on the
manager and restarts it there: the same runners, proxy and store as the real bot,
its own sessions folder and thread map. The real bot keeps the committed code.
It takes the controller tree it runs from and the sibling `fxa-agent-bot` tree, or the bot tree in
`FXA_DEV_BOT_ROOT`. The bot's `npm run e2e` takes the controller worktree on its own branch name, as CI does.

```bash
H=skills/fxa-manager/vm.sh D=skills/fxa-ctl-dev/slack-drive.sh
$H dev                           # deploy the working trees to the dev bot
ts=$($D start "<request>")       # @mention it in a new thread, as you
$D wait "$ts"                    # until ✅ or ⚠️, then the thread with times
$D reply "$ts" "<text>"          # a follow-up, or the answer to a question
$H dev report "$ts"              # quick answer, boot, turns, usage by model, subagents, errors
$H dev smoke                     # before a promote: deploys the trees itself (no $H dev before it), then fake-mode session, !status, !stop, a quick answer; ends on the real controller
$H dev fn '_answer_dns_gate'     # run the dev controller's functions on the VM (or: dev fn - <<'EOF' ... EOF)
$H dev log                       # the dev bot's log;  $H dev stop
$D show "$ts"                    # read a test-channel thread; the Slack MCP tools reach another workspace
```

For the bot's Slack messages alone (status lines, the PR card, CI lines), use
`FXA_DEV_FAKE=1 $H dev`: `fake-ctl.sh` plays each session on the clock, with no runner,
no push and no real PR (a draft PR event, then CI running, then passed after 60 s).
`!pr` stands in for Open PR. A plain `$H dev` goes back to the real controller.

The dev bot shares live's `.env` and Jira login, so `$H dev` gives the dev controller a fake Jira: its `acli`
is `fake-jira/acli`, which keeps tickets (keys from 90001) in `~fxa/dev/fake-jira` and logs each call to its
`calls.log`, and every Jira REST call fails. `FXA_DEV_REAL_JIRA=1 $H dev` writes to the real Jira; the next
plain `$H dev` turns it off.

Buttons cannot be pressed through the API: answer with a reply. The tokens are in
`fxa-agent-bot/.env.dev`. When it looks right: commit, push, `vm.sh promote`.

## Commit and deploy

1. Scoped conventional commit: `fix(gce): ...`, `feat(session): ...`.
2. From the worktree, run `bash skills/fxa-ctl-dev/ship.sh` (`--bot <bot tree>` for a bot change,
   default `../fxa-agent-bot-main`; `--smoke` deploys through `dev smoke`). It refuses a dirty tree,
   rebases each tree on origin/main, pushes the ones with commits, and runs `vm.sh dev` with both.
3. `bash skills/fxa-manager/vm.sh promote` deploys to the live bot (Mozilla Slack). It
   refuses unless `main` in both repos is exactly what the last `vm.sh dev` ran,
   uncommitted files included, and unless the bot's `npm test` and `npm run e2e` pass
   on that tree (about 5 min; `FXA_PROMOTE_SKIP_TESTS=1` skips them in an emergency).
   Then it syncs and checks the services. `vm.sh sync` alone
   skips that check: use it only for a change the dev bot cannot exercise.
   A change to shared state (`lib/db/` migrations, the MCP gateway, the LLM proxy,
   secrets) reaches live data as soon as dev runs it: test it with `vm.sh test` first.
   Ask the person "Promote now?" and run it yourself on their yes; do not hand them a `!` command.
   Do not push while a promote runs: the promote refuses a main that moved. Commit follow-up work
   locally, then ship it in one batch after the promote.
   Run the promote from the main checkout (the shell's start folder), as exactly
   `bash skills/fxa-manager/vm.sh promote`: no `cd`, path, env, pipe, wrapper (`perl alarm`,
   `timeout`) or `&&` chain after a dev smoke, since the allow rule matches only that text. Run the
   smoke, then the promote as its own command. From a worktree, the allow rules also match
   `bash /Users/vijaybudham/Desktop/working2/<tree>/skills/fxa-manager/vm.sh promote`, with an optional
   `FXA_DEV_BOT_ROOT=/Users/vijaybudham/Desktop/working2/<bot tree>` first. Run it in the background. With green CI it reads only origin/main and the dev record, which
   every worktree shares. Only when it must run the bot's tests itself does it need the trees
   dev ran: then it says "vm.sh dev again".

## After a promote that changed the dashboard

Render the live data once with the new page:

```bash
H=skills/fxa-manager/vm.sh
jq -n --slurpfile a <($H api snapshot) --slurpfile b <($H api stats) --slurpfile c <($H run 'python3 -c "import sys,json,time; sys.path.insert(0,\"lib\"); import fxadb; print(json.dumps(fxadb.routine_summary(fxadb.connect(readonly=True), int(time.time()))))"' | tail -1) \
  '{"/api/snapshot": $a[0], "/api/stats": $b[0], "/api/routines/summary": $c[0], "/api/team-admin": {"admin": true}}' > "$SCRATCH/fx.json"
cd dashboard-v2 && python3 e2e/serve.py --fixture "$SCRATCH/fx.json" --port 4180   # in the background
```

Open `#overview`, `#pipeline/belts`, `#runners` and `#stats/spend` at `http://localhost:4180/` in the browser pane. Each must render with no "This section did not render".
The routine summary comes from the store on the manager: `/api/routines/summary` needs a signed team admin.
Serve the same file with `"/api/team-admin": {"admin": false}` to see the Overview as a viewer who is not a team admin: it must show no routine name from the summary.

A section that throws shows "This section did not render". If it does, run `vm.sh rollback`, or revert the slices in reverse order and promote again.

## Restart the bot safely

The bot runs on the manager VM. On the laptop its `.env` is now `.env.retired`,
so no second bot starts there. The unit uses `KillMode=process`, so a restart
does not stop a session boot or an Open PR job that the bot started.
`vm.sh sync` restarts the bot when it runs.

To restart only the bot: `vm.sh sys 'sudo systemctl restart fxa-agent-bot'`.
Never run a second copy of the bot beside the first.

## FxA as a team record

FxA has a record `fxa` beside `profiles/fxa/profile.conf`. The conf wins unless `FXA_FXA_RECORD=1`.
`pipeline_load` keeps FxA's host names for either source, and `fxa-ai-fixme` stays an alias. A check that
loads FxA from the record copies `lib/testdata/fxa-team.json` (fake admins) into its `FXA_TEAMS_DIR` and
sets `FXA_VM_BACKEND=tart`. `lib/fxa-record.check.sh` diffs `profile env` with the switch off and on,
and lists the keys that may differ. The fxa record cannot be deleted, turned off or put in draft, and its
runner keys change only with the CLI (`skills/fxa-manager/SKILL.md` has the steps and the rollback).

## Errors

`fxa-sandbox-ctl errors` lists open error signatures from the controller and
the bot; `errors show <sig>` gives each occurrence; `errors resolve <sig> "<note>"`
closes one after a fix (it reopens if it happens again). A crash entry from a
handled failure is a bug in the ERR trap's filter or a missing `|| true`.

## The Firecracker snapshot

Slack sessions restore a snapshot with the FxA stack running. On the Firecracker
host, `fc-refresh.timer` runs `infra/firecracker/refresh.sh` every 30 minutes
while the host is up. It brings the clone to fxa main, installs when `yarn.lock`
moved, and takes a new snapshot. A failed refresh keeps the old snapshot, so
sessions still boot, but each one repeats the install and takes about 30 s more.
The `snapshot_refresh` and `snapshot_age` alerts report it.

```bash
H=skills/fxa-manager/vm.sh
$H fc              # the snapshot's fxa commit, Claude Code and Codex versions, age, and the last refresh result
                   # "# the runner host is stopped; last read:" above it: the values are from the last read, not now
$H fc log 120      # the last refresh's log
$H fc refresh      # start the host if it is stopped, install the repo's scripts, start a refresh
```

The host runs copies of `refresh.sh` and `packer/scripts/03b-toolchain.sh`.
`vm.sh sync` and `vm.sh fc refresh` install the repo's versions. A change to
either file reaches the host only through those two commands.

`03b-toolchain.sh` owns Node, Claude Code and Codex for the image and the snapshot.
It installs them in `/usr/local`, the prefix that comes first on PATH. It holds the
one pin for Claude Code and for Codex, which `lib/claude-pin.check.sh` checks. A
changed pin makes the next refresh run even when fxa main has not moved.
To bump both pins to the latest npm releases, run `bash skills/fxa-ctl-dev/bump-cli.sh`. Then commit,
ship and promote: a promote that changes `03b-toolchain.sh` or `refresh.sh` starts `fc refresh` itself.

Causes of a failed refresh, and their fixes:

| Log line | Cause | Fix |
|---|---|---|
| `fxa@workspace:. couldn't be built` with an old `node v…` | fxa changed `.nvmrc`; the preinstall refuses another Node | `03b-toolchain.sh` installs the `.nvmrc` release. Check the `node` line in the log. |
| `Class extends value undefined is not a constructor` | A Node release unpacked over another mixed two npm trees | `03b-toolchain.sh` removes npm and corepack first. Delete `/usr/local/.node-release` in the guest to force a clean install. |
| `esbuild … couldn't be built`, and `bin/esbuild:1` then ELF bytes in the build log | A rebuild ran esbuild's `install.js` on its native `bin/esbuild` | `refresh.sh` deletes `node_modules/.yarn-state.yml` so yarn relinks from its cache |
| `The CLOBBER file has been updated` | Firefox main needs a clobber build | The mozconfig has `AUTOCLOBBER=1` |
| A tool shows an old version after an install | Another copy comes earlier on PATH (`/usr/local/bin` before `/usr/bin`) | Find every copy with `which -a <tool>`, or read the snapshot disk with `debugfs -R "stat <path>" rootfs.ext4` |

Yarn writes each package's build log to `/tmp/xfs-*/build.log` in the guest, and
the guest's `/tmp` is gone after the refresh. `refresh.sh` prints those logs when
the install fails. Read them before you change anything.
