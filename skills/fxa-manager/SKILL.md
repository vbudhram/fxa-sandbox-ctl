---
name: fxa-manager
description: Use to operate the fxa-manager GCE VM that runs the fxa-sandbox-ctl controller, the fxa-agent Slack bot, the dashboard, and the pipeline timers. Covers status, deploying code, services, logs, secrets, the state mirror, and ssh. Works from the laptop (over IAP) or on the VM itself.
allowed-tools: Bash, Read, Grep
---

# Operate the manager VM

`fxa-manager` (project `moz-fx-dev-vbudhram-sandbox`, zone `us-central1-b`,
no public IP) runs the controller in place of the laptop. The design and the
cutover steps are in `ai/docs/exec-plans/2026-09-28-manager-vm.md`.

Use the helper for everything it covers. It runs on the laptop or on the VM:

```bash
H=~/Desktop/working2/fxa-sandbox-ctl/skills/fxa-manager/vm.sh
$H status              # start here
$H run '<command>'     # a shell command as fxa, in the controller repo
$H sys '<command>'     # as your own login user, who can sudo
$H screen              # read the tmux session "main"
$H sync                # pull both repos on the VM after a push
$H ssh                 # the ssh command for a person
```

## Rules

1. Only one Slack bot at a time. Socket Mode spreads events across every
   connected copy, so a bot on the laptop and one on the VM each take some
   messages. Stop one before you start the other.
2. Never print a secret. Show a secret as present or missing, or by its
   length. `vm.sh` masks known token formats; do not rely on that alone.
3. Pause the pipeline before you move work between hosts
   (`fxa-sandbox-ctl pause "<reason>"`). The pause marker is in GCS, so it
   holds on both hosts.
4. Do not type into the tmux session with `tmux send-keys` unless the person
   asks. Reading it with `vm.sh screen` is fine.
5. Every GCP change (IAM, firewall, secrets, instances) needs the person's go.
   The VM's service account cannot create secrets or change IAM, on purpose.

## Layout on the VM

| What | Where |
|---|---|
| Service user | `fxa`. People work as it: `sudo -iu fxa`, then `tmux new -As main` |
| Repos | `/home/fxa/Desktop/working2/{fxa-sandbox-ctl,fxa-agent-bot,fxa}` |
| Controller state, error log | `/home/fxa/.claude/state/{fxa-ai-fixme,agent-sessions}` |
| Env and key files | the repos' `.env`, `~/.config/fxa/github-app.pem`, `~/.circleci/cli.yml`, all written at boot |
| Units | `fxa-secrets` (boot), `fxa-agent-bot`, `fxa-dashboard`, `fxa-llm-proxy` (:8788), `fxa-mcp-gateway` (:8789), `fxa-pass.timer`, `fxa-triage.timer` |
| gh | `~/bin/gh`, a shim that acts as the fxa-agent GitHub App with a fresh token |

Runners are reached on the private network (`FXA_GCE_SSH_DIRECT=1`), not through IAP.

**Dashboard:** https://fxa-desktop-82056944052.us-central1.run.app/ (the Cloud
Run gateway, behind IAP; `DASHBOARD_USERS` on the service lists who may see
it). Desktops are at `/d/<session>` on the same host. The gateway reaches the
VM at `MANAGER_URL=http://10.42.2.2:8787`; if the VM is rebuilt and its private
address changes, redeploy the gateway with the new one.

## Tasks

**Stop spending (kill switch).** `fxa-sandbox-ctl sessions pause "<reason>"`
refuses new Slack sessions and resumes on every host (the marker is in GCS);
the bot answers a tag with the reason. Add `--now` to also stop the sessions
that are running, mid-turn included; their work is saved. `sessions resume`
undoes it; `sessions status` shows it. For the pipeline, use
`fxa-sandbox-ctl pause "<reason>"`. The hard ceiling is the Anthropic
workspace's spend limit in the Console.

**Deploy a change.** Commit and push on the laptop, then `vm.sh sync`. It
fast-forwards both repos, skips a repo with local edits on the VM, links new
repo skills, and restarts the bot and dashboard only if they run.

**Services.** `fxa` has no sudo; use `sys`, which runs as your login user:
```bash
$H sys 'systemctl status fxa-agent-bot --no-pager | head -12'
$H sys 'sudo systemctl restart fxa-agent-bot'
$H sys 'sudo journalctl -u fxa-agent-bot -n 50 --no-pager'   # timers: -u fxa-pass
```

**Add or rotate a secret.** The person runs, on the laptop:
`gcloud secrets versions add <name> --data-file=<file>` (or `secrets create`
plus `add-iam-policy-binding` for the manager service account with
`roles/secretmanager.secretAccessor`). Load values from a file, never paste
them into a command line. Then on the VM: `sudo /usr/local/sbin/fxa-secrets`
and restart the service that uses it. The runners' Claude credential is
`fxa-anthropic-api-key` (preferred) or `fxa-claude-token`.

**State mirror.** Pipeline state and the error log are in
`~/.claude/state/fxa-ai-fixme`, mirrored to GCS: `unlock` pushes after every
pass; a pull is manual (`fxa-sandbox-ctl state pull`). Pull only with no pass
holding the lock, and never while another host is still running passes.

**Change the VM itself.** `bash infra/gce/manager.sh` reprovisions (safe to run
again). It sends your Claude setup and the `.env` files without secrets, and
runs `infra/gce/manager-setup.sh` as root.

## When something fails

| Symptom | Cause, fix |
|---|---|
| `Permission denied (publickey)` from the laptop | The key `~/.ssh/google_compute_engine` has a passphrase and is not in the agent: `ssh-add --apple-use-keychain ~/.ssh/google_compute_engine` |
| `Connection timed out during banner exchange` | An IAP blip. The controller retries; for a person, try again |
| status shows `MISSING: runners cannot start` | No Claude credential in the controller `.env`: add the API key secret, run `fxa-secrets` |
| a secret shows missing | It does not exist, or the service account lacks `secretAccessor` on it |
| a repo shows commits behind | `vm.sh sync` |
| `yarn install` fails in `fxa` | FxA needs the exact Node in its `.nvmrc`; rerun `manager.sh`, which installs it |
