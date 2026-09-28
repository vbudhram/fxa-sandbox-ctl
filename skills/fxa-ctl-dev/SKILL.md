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

## Commit and deploy

1. Scoped conventional commit: `fix(gce): ...`, `feat(session): ...`.
2. Push both repos when the manager VM needs the change.
3. `bash skills/fxa-manager/vm.sh sync` fast-forwards the VM's checkouts.

## Restart the bot safely

The bot runs on the laptop until the cutover, on the VM after it. Before a
restart, make sure no session job is running, or a wrap-up or a launch is cut:

```bash
pgrep -fl 'session-boot|session-finish' || echo "no session jobs"
```

On the VM: `vm.sh sys 'sudo systemctl restart fxa-agent-bot'`. Never run a
second copy of the bot beside the first.

## Errors

`fxa-sandbox-ctl errors` lists open error signatures from the controller and
the bot; `errors show <sig>` gives each occurrence; `errors resolve <sig> "<note>"`
closes one after a fix (it reopens if it happens again). A crash entry from a
handled failure is a bug in the ERR trap's filter or a missing `|| true`.
