---
name: fxa-session-debug
description: Use when a Slack agent session failed, stalled, or said "Something went wrong", or someone pastes the fxa-agent thread and asks what happened. Collects the session's record, boot and finish logs, recorded errors and last messages, and maps the symptom to a known cause and fix.
allowed-tools: Bash, Read, Grep
---

# Why did this session fail?

## 1. Find the session and collect everything

```bash
bash ~/Desktop/working2/fxa-sandbox-ctl/skills/fxa-session-debug/why.sh [agent-xxxx]
```

With no key it takes the newest session. A pasted thread rarely shows the
key; the newest session, or `fxa-sandbox-ctl session list`, usually finds it.
After the cutover the controller runs on the manager VM:

```bash
bash ~/Desktop/working2/fxa-sandbox-ctl/skills/fxa-manager/vm.sh run 'bash skills/fxa-session-debug/why.sh agent-xxxx'
```

The script masks known token formats. Never print a `.env` or a token.

## 2. Match the symptom

| In the thread or the log | Cause | What to do |
|---|---|---|
| `runner is at '', slot is at '<sha>'` or `could not reach the runner to pin it` | The IAP ssh failed at the pin step | Retried now; if it keeps failing, IAP is degraded. Try again later |
| `egress firewall did not apply` | The IAP ssh failed at the firewall step | Same as above |
| `Connection timed out during banner exchange` | An IAP tunnel blip before login | `_gce_ssh` retries 3 times with a 30 s wait |
| `gcloud.compute.instances.create ... Internal error` | GCP's own fault | `vm_clone` now tries the next zone |
| `stocked out` in every zone | No capacity for `c4a-highcpu-4` | Wait, or set `FXA_GCE_ZONES` |
| `I paused: this session reached its usage limit` | The bot's cost cap (`SESSION_COST_CAP`, default $15) | A reply resumes with a new limit; raise the cap in the bot's `.env` |
| `I'll pause since it's been quiet` | 30 min with no turn (`FXA_SESSION_IDLE_SECONDS`) | A reply resumes; an open desktop counts as activity |
| `I wrote no handoff, so nothing was pushed` | The agent chose not to ship; its reason is in the reply above it | Read the reply; steer and try again |
| `could not reach the sandbox to read the handoff` | ssh dropped after the wrap-up | The work is still there; try Open PR again |
| `nothing to push: no files changed` | The session changed no files | Nothing to ship |
| `set ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN` | The host has no Claude credential for runners | Add the secret, run `fxa-secrets` on the VM |
| `Setup failed` after `Done` in older threads | Only the status wording (fixed) | Look at the error line below it |
| a crash entry `ctl/crash` in the errors | An unexpected failure inside the controller | `fxa-sandbox-ctl errors show <sig>`; fix, then `errors resolve` |

## 3. Report

Say, in plain words: what the person saw, what actually failed (quote one log
line), whether their work is safe, and what they can do now (usually "tag me
again" or "reply here"). If it is a new cause, fix it with `/fxa-ctl-dev`,
add a row to this table, and resolve the error signature.
