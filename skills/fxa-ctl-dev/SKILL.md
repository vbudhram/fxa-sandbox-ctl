---
name: fxa-ctl-dev
description: Use when you change fxa-sandbox-ctl (the controller) or fxa-agent-bot (the Slack bot). Covers where things are, the portability rules (macOS and the Linux manager VM), running the checks on both, committing, deploying to the manager VM, and when a bot restart is safe.
allowed-tools: Bash, Read, Edit, Write, Grep, Glob
---

# Change the controller or the bot

Before a product decision (a new setting, message, button, team feature or guard), read `PRODUCT.md`: its goals, principles and defaults decide.

Before you change `dashboard/index.html`, read `guide/dashboard-design.md`. It gives the tokens, the
component helpers, and the checks and screenshots that verify a dashboard change.

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
| Host state | `~/.claude/state/fxa-ai-fixme` (pipeline, `errors.jsonl`), `~/.claude/state/agent-sessions` |

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
`git diff --cached` before each commit. `vm.sh dev` and `vm.sh promote` work from
whichever tree you run them in.

## Rules for the code

1. **Two hosts.** The controller runs on macOS (bash 3.2, BSD tools) and on
   the Ubuntu manager VM (bash 5, GNU tools). Use the helpers in
   `lib/config.sh`: `_mtime`, `_btime`, `_fsize`, `_epoch_of`, `_free_gb`.
   Never call `stat -f`, `df -g` or `date -j` directly: on Linux `stat -f`
   succeeds and prints the wrong thing. No associative arrays, `mapfile` or
   `${x,,}`. `mktemp` templates end in `XXXXXX`.
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

Run `test.sh changed` before each push, and let CI run the full suite. Use `test.sh`, not a loop of your own: it counts a check that
fails to start or exits nonzero as a failure. (A hand loop once reported "all pass"
because macOS has no `timeout`, so no check ran.)

To replace exact text, use `python3 ~/.claude/skills/fxa-ctl-dev/rep.py <file> < pairs.json` (`[["old", "new"], ...]`), or `rep.py < triples.json` (`[["file", "old", "new"], ...]`) for several files. For code with quotes or backslashes, use `rep.py --blocks` with a heredoc of `<<<< path`, old lines, `====`, new lines, `>>>>`: no JSON to escape. Block text is literal: write `"` and `\`, never `\"`. Each old text must match once; on a miss, nothing is written to any file. Do not write an inline `def rep(` or `def sub(` heredoc. `python3 rep_test.py` checks the script.

To answer "is everything shipped?" or "what is the status?", run `bash skills/fxa-ctl-dev/shipped.sh` first (about 15 s; `--no-live` skips the manager). It lists work not on origin/main with its CI state, main against the dev deploy and the live bot, and the backlog items that wait.

To render a dashboard view with live data and this tree's dashboard code, with no dev bot: `bash skills/fxa-ctl-dev/live-render.sh '#runners' [--admin] [--query 'ended=1&limit=100'] [page.sh options]` (about 15 s). A change to `lib/snapshot.sh` still needs `vm.sh dev`.

A new check must fail without the change it tests. `prove.sh` runs it with the
change, then with the named files put back to `HEAD`, and restores them.

A change to a function with outside calls gets a stubbed test: define the
outside command as a shell function that fails the first time, then check
the retry. Put a counter in a file, not a variable: `$(...)` runs in a subshell.

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
| A profile's guest scripts (provision, boot, ready) | `skills/fxa-ctl-dev/devslot.sh up <profile>` (the manager's `.env` gives the host), then `sync <profile> <guest dir>=<local dir>`, `run <profile> - < script.sh`, `reset`, `down`: a warm Firecracker slot. About 7 s for each run or reset, 17 s to sync 24 MB. The host stops an unused dev slot after 30 min |
| A dashboard view (focus, routes, layout) | `skills/fxa-ctl-dev/page.sh '#teams/example' --probe '<async js>'` or `--shot out.png`: headless Chrome, fetch stubbed from `page-fixture.json` (or `--fixture`), about 3 s. Blur before a route change in a focus probe, or the focus can stay from the last route |
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

Buttons cannot be pressed through the API: answer with a reply. The tokens are in
`fxa-agent-bot/.env.dev`. When it looks right: commit, push, `vm.sh promote`.

## Commit and deploy

1. Scoped conventional commit: `fix(gce): ...`, `feat(session): ...`.
2. Push both repos when the manager VM needs the change.
3. `bash skills/fxa-manager/vm.sh promote` deploys to the live bot (Mozilla Slack). It
   refuses unless `main` in both repos is exactly what the last `vm.sh dev` ran,
   uncommitted files included, and unless the bot's `npm test` and `npm run e2e` pass
   on that tree (about 5 min; `FXA_PROMOTE_SKIP_TESTS=1` skips them in an emergency).
   Then it syncs and checks the services. `vm.sh sync` alone
   skips that check: use it only for a change the dev bot cannot exercise.
   A change to shared state (`lib/db/` migrations, the MCP gateway, the LLM proxy,
   secrets) reaches live data as soon as dev runs it: test it with `vm.sh test` first.
   Run the promote as one plain command, with no `cd ... &&` in front: an allow rule
   matches only the start of the command. From a worktree, give vm.sh's absolute path
   (it finds its tree from its own path), with `FXA_DEV_BOT_ROOT=<bot tree>` first when needed.

## After a promote that changed the dashboard

Render the live data once with the new page:

```bash
H=skills/fxa-manager/vm.sh
jq -n --slurpfile a <($H api snapshot) --slurpfile b <($H api stats) --slurpfile c <($H run 'python3 -c "import sys,json,time; sys.path.insert(0,\"lib\"); import fxadb; print(json.dumps(fxadb.routine_summary(fxadb.connect(readonly=True), int(time.time()))))"' | tail -1) \
  '{"/api/snapshot": $a[0], "/api/stats": $b[0], "/api/routines/summary": $c[0], "/api/team-admin": {"admin": true}}' > "$SCRATCH/fx.json"
for r in '#overview' '#pipeline/belts' '#runners' '#stats/spend'; do
  bash skills/fxa-ctl-dev/page.sh "$r" --fixture "$SCRATCH/fx.json" --probe 'return document.getElementById("main").innerText.includes("did not render")'
done
# The routine summary comes from the store on the manager: /api/routines/summary needs a signed team admin.
# Overview as a viewer who is not a team admin: prints false when no routine name from the summary shows.
jq '. + {"/api/team-admin": {"admin": false}}' "$SCRATCH/fx.json" > "$SCRATCH/fx-user.json"
names="$(jq -c '[."/api/routines/summary".routines[]?.name]' "$SCRATCH/fx.json")"
bash skills/fxa-ctl-dev/page.sh '#overview' --fixture "$SCRATCH/fx-user.json" --probe "const n = $names, t = document.getElementById('ov-sys').innerText + document.getElementById('ov-floor').innerText; return n.some(x => t.includes(x))"
```

`page-fixture-overview.json` is a sample-data fixture for the Overview; it takes `@iso-3600` and
`@epoch+600` style times relative to the run. Headless Chrome keeps the window at least 500 px wide.

A section that throws shows "This section did not render". If it does, run `vm.sh rollback`, or revert the slices in reverse order and promote again.

## Restart the bot safely

The bot runs on the manager VM. On the laptop its `.env` is now `.env.retired`,
so no second bot starts there. The unit uses `KillMode=process`, so a restart
does not stop a session boot or an Open PR job that the bot started.
`vm.sh sync` restarts the bot when it runs.

To restart only the bot: `vm.sh sys 'sudo systemctl restart fxa-agent-bot'`.
Never run a second copy of the bot beside the first.

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
