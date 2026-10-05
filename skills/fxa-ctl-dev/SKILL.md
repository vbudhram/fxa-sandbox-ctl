---
name: fxa-ctl-dev
description: Use when you change fxa-sandbox-ctl (the controller) or fxa-agent-bot (the Slack bot). Covers where things are, the portability rules (macOS and the Linux manager VM), running the checks on both, committing, deploying to the manager VM, and when a bot restart is safe.
allowed-tools: Bash, Read, Edit, Write, Grep, Glob
---

# Change the controller or the bot

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

## Test

```bash
bash skills/fxa-ctl-dev/test.sh        # macOS, then Ubuntu 24.04 in docker
bash skills/fxa-ctl-dev/test.sh mac    # quick
cd ~/Desktop/working2/fxa-agent-bot && npm test
```

A change to a function with outside calls gets a stubbed test: define the
outside command as a shell function that fails the first time, then check
the retry. Put a counter in a file, not a variable: `$(...)` runs in a subshell.

## Try a change before you deploy

| What changed | Try it with |
|---|---|
| A runner prompt, a subagent, a skill | `skills/fxa-ctl-dev/agent-try.sh "<request>"`: on the laptop, about 20 s; no stack |
| Anything a runner does | `fxa-sandbox-ctl session try --prompt "<request>"` on the manager: a real runner, no Slack |
| The bot, or the whole path from Slack | the dev bot, below |

The dev bot is the app `fxa-agent-dev` in a private test channel. `vm.sh dev` copies
the working trees of both repos (uncommitted changes too) to `~fxa/dev` on the
manager and restarts it there: the same runners, proxy and store as the real bot,
its own sessions folder and thread map. The real bot keeps the committed code.

```bash
H=skills/fxa-manager/vm.sh D=skills/fxa-ctl-dev/slack-drive.sh
$H dev                           # deploy the working trees to the dev bot
ts=$($D start "<request>")       # @mention it in a new thread, as you
$D wait "$ts"                    # until ✅ or ⚠️, then the thread with times
$D reply "$ts" "<text>"          # a follow-up, or the answer to a question
$H dev report "$ts"              # quick answer, boot, turns, usage by model, subagents, errors
$H dev log                       # the dev bot's log;  $H dev stop
```

Buttons cannot be pressed through the API: answer with a reply. The tokens are in
`fxa-agent-bot/.env.dev`. When it looks right: commit, push, `vm.sh sync`.

## Commit and deploy

1. Scoped conventional commit: `fix(gce): ...`, `feat(session): ...`.
2. Push both repos when the manager VM needs the change.
3. `bash skills/fxa-manager/vm.sh sync` fast-forwards the VM's checkouts.

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
