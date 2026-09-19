This document describes the system that turns a labelled Jira ticket into a reviewable
GitHub pull request with no human in the loop. It is written for an engineering team that
must operate, extend, or rebuild the pipeline.

`README.md` documents `fxa-sandbox-ctl` as a standalone tool. `VM_AGENT_GUIDE.md` documents
the environment from inside the VM. This document covers the layer above both: the lifecycle
of a ticket, the loops that move it, and the contract between each component.

**Section 3 is the spine.** It follows one ticket from label to merge. Every other section is
reference detail for a stage in it.

---

# 1. What the pipeline does

A reporter puts the label `ai-fixme` on a Jira ticket. Within the hour, one of two things
happens:

- A pull request opens against `mozilla/fxa`, CI passes, and the ticket moves to
  `ai-fixme-done`. A human reviews and merges it.
- The pipeline declines the ticket, records why, and posts one comment that names the decision
  a human must make.

The pipeline never merges. It never approves. It stops at review-ready.

## Scope boundaries

| In scope | Out of scope |
|---|---|
| Public `mozilla/fxa` tickets labelled `ai-fixme` | The private security repo (a separate skill covers it) |
| One ticket, one agent, one PR | Multi-train work, DB migrations, published package surfaces |
| Fixes an agent can verify with unit tests and lint | Anything that needs production data or credentials |
| Two rounds of automated review-comment fixes | Merging, approving, or release decisions |

---

# 2. Component map

The system is four parts. Only one of them lives in this repository.

```
  ┌─────────────────────────────────────────────────────────────────┐
  │ SCHEDULER          Claude Code cron jobs, session-only          │
  │                    (see §6 for the durable alternative)         │
  └────────────────────────────┬────────────────────────────────────┘
                               │ fires a prompt
  ┌────────────────────────────▼────────────────────────────────────┐
  │ PASS LOGIC         skills/fxa-ai-fixme/ in this repository      │
  │                      SKILL.md       the decision rules          │
  │                      SCHEDULING.md  the loop definitions        │
  │                    Symlinked from ~/.claude/skills/             │
  │                    State: Jira labels + ~/.claude/state/        │
  └────────────────────────────┬────────────────────────────────────┘
                               │ fxa-sandbox-ctl <command> ...
  ┌────────────────────────────▼────────────────────────────────────┐
  │ ORCHESTRATOR       this repository                              │
  │                      fxa-sandbox-ctl  CLI entry point           │
  │                      pipelines/*.conf what is repo-specific     │
  │                      lib/pipeline.sh  pass state, lock, skips   │
  │                      lib/jira.sh      queue, labels, tickets    │
  │                      lib/github.sh    PR state, review comments │
  │                      lib/telemetry.sh tokens, cost, run log     │
  │                      lib/worktree.sh  git worktree pool         │
  │                      lib/vm.sh        tart VM lifecycle         │
  │                      lib/agent.sh     boot, harden, start agent │
  │                      lib/finish.sh    handoff, push, PR, CI     │
  │                      packer/          golden image build        │
  └────────────────────────────┬────────────────────────────────────┘
                               │ virtiofs mount + screen session
  ┌────────────────────────────▼────────────────────────────────────┐
  │ AGENT VM           Ubuntu 24.04 ARM64 under tart                │
  │                      Claude Code, bypassPermissions             │
  │                      /workspace = the host worktree             │
  │                      Contract: VM_AGENT_GUIDE.md Part 3         │
  └─────────────────────────────────────────────────────────────────┘
```

**The pass logic is in this repository.** `skills/fxa-ai-fixme/` holds it, and
`~/.claude/skills/fxa-ai-fixme` is a symlink to it. The mechanical half of the pipeline (the
queue reads, the label writes, the pool, VM reaping, PR state, telemetry) is `fxa-sandbox-ctl`
itself. What stays in `SKILL.md` is judgment: what to admit, what to verify, when to comment.
See §11.

---

# 3. The lifecycle of one ticket

## 3.1 Overview

```
  [Stage 0]  reporter adds the label  ai-fixme
      |
      v
  [Stage 1]  QUEUED  <-------------------------------------+
      |                                                    |
      v                                                    |
  [Stage 2]  admission + grounding                         |
      |                                                    |
      +-- underspecified / blocked --> record fingerprint --+
      |                                comment once, then silent
      |
      +-- code already satisfies it --> EXIT: recommend closing
      |
      v  admit
  [ a claimable slot?  ctl freeslots ]
      |
      +-- none free ----------------------------------> back to QUEUED
      |
      v  claim one
  [Stage 3]  label inflight, launch on slot  <-------------+
      |                                                    |
      v                                                    |
  [Stage 4]  worktree prep, branch, context, render goal   |
      |                                                    |
      +-- goal over 4100 chars --> EXIT: blocked           |
      |                                                    |
      v                                                    |
  [Stage 5]  VM boot + hardening                           |
      |                                                    |
      v                                                    |
  [Stage 6]  agent run, 30 turns, writes handoff JSON      |
      |                                                    |
      +-- VM dead --> relaunched once? -- no --------------+
      |                     |                              |
      |                     +-- yes --> EXIT: blocked      |
      v  handoff file, valid JSON + real work              |
  [Stage 7]  host: stage, squash, sign, push               |
             gh pr create, reviewers, approve gate         |
      |                                                    |
      v                                                    |
  [ check-in reclaims the VM: usage -> record -> stop ]    |
      |                                                    |
      v                                                    |
  [Stage 8]  CI settled?                                   |
      |                                                    |
      +-- flake, under 2 reruns per SHA --> rerun, loop    |
      |                                                    |
      +-- real failure, under 2 attempts -----------------+
      |                                                    |
      +-- cap reached --> EXIT: blocked                    |
      |                                                    |
      v  all green                                         |
  [Stage 9]  ai-fixme-done: PR open + green, slot free     |
      |                                                    |
      +-- verified review feedback, under 2 rounds -------+
      |                                                    |
      +-- 2 rounds spent --> EXIT: blocked                 |
      |
      v  no unhandled comments
  [Stage 10]  drain
      |
      +-- still open and green --> back to Stage 9
      +-- MERGED ---------------> EXIT: ai-fixme-merged    (terminal)
      +-- CLOSED unmerged ------> EXIT: ai-fixme-rejected  (terminal)
```

Three loops matter more than the straight line through the middle:

- The skip loop parks a ticket back in the queue. A skipped ticket stays visible, and it
  re-enters only when its text changes.
- Stage 8 and stage 9 both re-enter stage 3 on the **same slot**. That is why a ticket owns
  its worktree until its label leaves `inflight`.
- Stage 10 finding the PR still open and green is a no-op, which is the common case.

Ten stages. The label column is the ticket's durable state at that moment. The actor column
says which component does the work, which matters because only one of them holds the GitHub
credentials and only one of them can decide.

| # | Stage | Label | Actor | Typical duration |
|---|---|---|---|---|
| 0 | Labelled | `ai-fixme` | Reporter | instant |
| 1 | Queued | `ai-fixme` | none, waiting | minutes to indefinite |
| 2 | Admission and grounding | `ai-fixme` | Pass | 1 to 3 minutes |
| 3 | Claim and launch | `ai-fixme-inflight` | Pass | seconds |
| 4 | Worktree preparation | `ai-fixme-inflight` | Orchestrator | 10 to 60 seconds |
| 5 | VM boot and hardening | `ai-fixme-inflight` | Orchestrator | 1 to 2 minutes |
| 6 | Agent run | `ai-fixme-inflight` | Agent VM | 10 to 20 minutes |
| 7 | Host handoff | `ai-fixme-inflight` | Orchestrator | about 1 minute |
| 8 | CI settle and reconcile | `ai-fixme-inflight` | CI, then Pass | 20 to 40 minutes |
| 9 | Human review | `ai-fixme-done` | Reviewer | hours to days |
| 10 | Drain | `merged` or `rejected` | Pass | seconds |

Stages 0 to 8 are automated and usually finish inside an hour. Stage 9 is where work actually
queues. Review throughput, not agent throughput, is the pipeline's bottleneck.

## 3.2 Stage by stage

### Stage 0: Labelled

A reporter adds the bare label `ai-fixme`. No pipeline state exists yet. Nothing is written
anywhere else.

### Stage 1: Queued

`$CTL queue` runs the JQL `labels = "ai-fixme" AND statusCategory != Done`, ordered oldest
first. The ticket appears there and stays until a pass admits it.

A ticket can sit here indefinitely, and that is by design. Three things hold it:

- Both pool slots are busy.
- It already failed admission, so it is in the skip list.
- Nobody armed the crons.

A skipped ticket keeps its bare `ai-fixme` label on purpose, so a human still sees it. The
consequence is that the queue is not a work list. `$CTL skipped` is what tells you which
entries are actually launchable.

### Stage 2: Admission and grounding

The pass takes the oldest key and grounds it. **The gate applies to that one ticket, not to the
queue.** The pass does not triage. It admits or skips one ticket, then stops.

Grounding, in order:

1. `$CTL ticket <KEY>` reads the description **and every comment**. `acli jira workitem
   view` silently omits comments, so description-only grounding looks complete. On 2026-08-13
   FXA-14325 was skipped for two questions the reporter had already answered in a comment.
2. Grep the repo, always against `origin/main`, never the working tree. The local checkout can
   sit on any branch. On 2026-08-11 it was 1253 commits behind and reported a file as missing
   that exists on `main`.
3. Answer four questions from the code, not from the ticket text. Is it already fixed? Do the
   named files still exist? Is the premise still true? Is the proposed approach still the best
   one? Tickets in this queue are often years old, and a verdict from a stale description is
   wrong in the most expensive way.
4. Read `_scripts/check-frozen.ts` on `origin/main` whenever the grep hits
   `packages/fxa-auth-server`. Frozen paths cannot be committed at all, because
   `yarn check:frozen` runs in the pre-commit hook.
5. Fetch a Figma design, but only if the ticket text contains a `figma.com` URL. **The VM has
   no MCP,** so the pass is the only place a design can enter the pipeline.

Budget: **10 tool calls, plus 3 for Figma.** The VM agent does the deep investigation.

The output is `/tmp/fxa-<KEY>-context.md` with four parts: scope, likely files, acceptance
criteria, and out-of-scope paths. It also carries a verification budget, because an agent left
to choose its own picks far too much. On FXA-14299 the agent spent 45 of its 58 minutes on a
package-wide lint for a 9 line test-only change.

**Exit: skip.** `$CTL skip <KEY> "<reason>"` records a fingerprint of the whole ticket and
prints `comment` or `silent <n>`. Post the 🤖 Jira comment only on `comment`. The ticket returns
to stage 1 with its label untouched. Without the fingerprint, the oldest and least launchable
tickets collect one identical comment every hour, forever.

### Stage 3: Claim and launch

Four actions, in this order:

1. `$CTL freeslots` picks a claimable slot. **Not `slots`.** See §7.
2. `export FXA_PR_ASSIGNEE="$($CTL reporter <KEY>)"` resolves the reporter's GitHub login.
   An empty result is fine and means the team gets the review request alone.
3. `$CTL label <KEY> inflight`. The ticket now owns the slot.
4. `$CTL launch <KEY> <slot> <ctx>` runs `fxa-sandbox-ctl jira <KEY> --create-pr
   --worktree <slot> --guardrails <ctx>` under `nohup` and returns at once. A pass never blocks
   on a VM.

The launcher's stdout goes to `~/.claude/state/fxa-ai-fixme/<KEY>.launch.log`. **That log is the
authoritative record of what the host did.** Read `$CTL progress <KEY>` before you draw any
conclusion from process state.

`launch` refuses below `FXA_MIN_FREE_GB`, 25GB by default. It also deletes the skip fingerprint,
so a later skip on the same key is never silenced by a stale match.

**Label and launch in one step.** Jira's JQL index lags a label write by several seconds, so an
`inflight` query taken right after the write may omit the ticket. A pass could then believe the
slot is free and launch a second agent onto the same worktree. The one-launch-per-pass rule is
what prevents this.

### Stage 4: Worktree preparation

Inside `fxa-sandbox-ctl jira`:

1. `jira_fetch_context` pulls the ticket through `acli`, including comments, and converts ADF to
   markdown.
2. The `--guardrails` file is prepended under a header that gives it precedence over the ticket
   text. **This is how the pass steers the agent**, including telling it to ignore a stale
   ticket instruction.
3. `worktree_prepare_for_issue` claims the named slot, fetches `origin/main`, and checks out or
   creates the branch `fxa-<key-lowercased>`. Git hooks are skipped on the swap, because FxA's
   post-checkout hook clones `external/l10n` and is not idempotent.
4. Any stale handoff file in the slot is archived, and the agent stream logs are truncated.
5. The context is written to `<worktree>/.fxa-jira-context.md`.
6. `_jira_render_prompt` builds the `/goal` directive.

**The 4000 character cap on `/goal` is a hard failure mode.** Claude Code rejects a longer
directive and then runs with no goal at all. The agent boots, sits at an empty prompt, and
`progress` reports a healthy `watching` forever. That is the worst shape a failure can take,
because nothing looks wrong. FXA-14104's 122 character title pushed the goal to 4032 counted
characters and the agent sat idle for 57 minutes. The tool now caps the raw render at 4100 and
fails the launch instead. Do not raise the cap; shorten the renderer.

Secrets are copied into the worktree only with `--functional-tests`. The worktree is mounted
into a VM running an agent with `bypassPermissions` whose prompt is built from Jira text, so an
unused credential is avoidable exposure.

### Stage 5: VM boot and hardening

`agent_run` clones the `fxa-dev-base` golden image, which Packer built from ten provisioner
scripts. It sets CPU and memory, then starts the VM with two virtiofs mounts:

- `workspace` maps to the slot worktree, read-write.
- `gitdir` maps to the repo's shared `.git` directory, **read-only**. That directory holds the
  admin files for every worktree, not just this one. Mounted read-write, a `bypassPermissions`
  agent could rewrite a sibling worktree's gitdir pointer, and on 2026-08-14 it did exactly that
  to three of them.

Hardening then runs on every boot, not in the image, so an old image cannot ship a weaker
policy:

1. Stop the proxy and strip proxy variables from the environment.
2. Install an egress firewall. It drops `10/8`, `172.16/12`, `192.168/16`, and `169.254/16`, so
   the VM reaches the public internet but cannot probe the host.
3. Disable SSH password authentication and install a per-agent key.
4. Replace blanket `NOPASSWD:ALL` sudo with an allow-list.

`_setup_claude_config` then tars hooks, commands, plugin cache, and an **allow-list** of skills,
and SCPs the bundle in. The allow-list matters: the VM has no `gh`, no `acli`, no CircleCI
credential, and no MCP. A skill that reaches the network is worse than useless there, because
the agent reads its description, judges it relevant, and then fails on a missing binary.

Claude Code starts inside a `screen` session named `claude`, with `--permission-mode
bypassPermissions`. The OAuth token is written to `/workspace/.fxa-auto-token`, sourced once,
and deleted. The `/goal` prompt is pasted into the TUI after an 8 second delay.

**`$CTL alive` reports `no-vm` for about the first minute here, and that is correct.** The
VM is booting and Claude has not started. A check-in rule of "DEAD means escalate" fires in this
window and relaunches a healthy agent, which is why the DEAD test is gated on the `progress`
stage word.

### Stage 6: Agent run

The agent runs a `/goal` loop with a 30-turn cap. The evaluator judges the transcript after each
turn, so the agent must print evidence of every criterion. The eight conditions are in
`VM_AGENT_GUIDE.md` Part 3: a plan, unit tests, lint per changed package, functional tests (off
by default), `/code-simplifier`, `/fxa-review-quick`, a scoped conventional commit with no scope
creep, then `/fxa-vm-selfcheck`, `/create-pr-description`, `/humanizer`, and the handoff file.

**The agent cannot commit and cannot push.** The read-only gitdir mount blocks the commit, and a
linked worktree's commit would write to the shared `.git/objects` and `.git/refs` anyway. The
boundary rules forbid `git push` and `gh` outright. The agent leaves the worktree dirty and
writes the handoff.

| The host writes | The agent writes |
|---|---|
| `.fxa-jira-context.md` | `.fxa-auto-done.json` |
| `.fxa-auto-token`, deleted on read | `.fxa-auto-media/`, optional |
| `.fxa-auto-prompt.txt` | |

The handoff JSON carries `issue`, `branch`, `commit_sha`, `pr_title`, `pr_body`, and
`media_paths`. `pr_title` must equal the commit subject exactly.

Run length is the main variable in the whole lifecycle. Ten to twenty minutes is typical. A 58
minute run has succeeded. **Do not judge a run by CPU or by `tail`.** On 2026-08-11 a run was
called stalled from process sampling while the launcher log already held `PR opened`.

### Stage 7: Host handoff

`finish_wait_for_done` polls the slot for the handoff file. It requires valid JSON **and** real
work in the worktree, so an agent that writes the handoff before doing the work does not trigger
a push.

`finish_push_and_pr` then:

1. Verifies the worktree is on the branch the handoff names.
2. Stages exactly what `worktree_filtered_status` reports, so the same ignore list that decides
   "dirty" decides what gets committed. A blanket `git add -A` would sweep in `newKey.json` and
   the `.fxa-auto-*` scratch files.
3. Squashes to the merge-base with the base branch and re-commits **on the host**, which picks up
   the operator's GPG or SSH signing key. The VM has no access to that key, so any in-VM commit
   would land unsigned. The squash uses the base branch, not `main`, so a release branch such as
   `train-342` does not collapse its own history into the PR.
4. Pushes and runs `gh pr create`.
5. `finish_add_reviewers` requests review from `mozilla/fxa-devs` and assigns the reporter. Both
   run **after** the create, never as flags on it, so a bad handle cannot fail the create and
   lose a PR that took 20 minutes to produce. Both failures are logged and ignored. `gh pr edit`
   is broken on this repo, because it queries a deprecated Projects-classic GraphQL field, so
   these use the REST endpoints.
6. `finish_approve_functional_gate` polls CircleCI for up to 3 minutes, finds the on-hold
   approval job matching `Functional`, and approves it.
7. `finish_watch_ci` waits for checks to attach, then polls until they settle.

The launcher then exits. **It does not stop the VM,** and it prints "the agent keeps running".

### Stage 8: CI settle and reconcile

Two loops act here.

**The check-in reclaims the VM.** Once a PR exists, the agent has no work left, and the VM holds
4 vCPU and 8GB for the whole 20 to 40 minute CI run. The check-in stops it. Order matters:

```
$CTL tokens <KEY>     # token counts live INSIDE the VM; stop deletes them
$CTL record <KEY>    # append the run to the local dataset
$CTL stop <agent-name>
```

This creates the pipeline's most confusing state. The label stays `inflight` while CI runs, so
`alive` correctly reports DEAD for a healthy ticket. Key the DEAD rule on "no PR", not on the
process.

**The pass reconciles.** It reads `$CTL progress` first, then `prstate`.

| `progress` says | Action |
|---|---|
| `pr <url>` | Go to the PR rows below. |
| `pushed` or `squashing` | The host is mid-handoff. Leave it. |
| `watching <n>s`, VM alive | Working. Leave it. |
| `watching <n>s`, VM dead | Failed launch. Relaunch **once**. Second failure means `blocked`. |
| `error <line>` | The push or the PR failed. Report the line. Do not relaunch. |
| `nolog` | Orphaned label from a dead pass. Return it to the queue. |
| PR open, checks running | Leave it. The next pass revisits. |
| PR open, all green | Label `done`. That reaps the VM and 👍s any fixed comments. The slot frees. |
| PR open, `fail>0` and `running=0`, thin set | **Settled by failure. Reconcile now.** |
| PR open, failure is a flake | Rerun. Two per head SHA at most. |
| PR open, failure is real | Relaunch on the same slot with the failure log, then re-approve the gate. Back to stage 3. |
| Two real fix attempts spent | Label `blocked`. |

**"Settled" needs a check count, not just `running=0`.** That value has two meanings: CI
finished, or CI has not started. A full FxA PR carries 18 to 21 checks. On 2026-08-12 FXA-14114
read `ok=9 fail=0 running=0` seconds after the gate was approved, while 7 gate-dependent jobs did
not exist yet. A pass in that window would have labelled it `done` with its key test never run.
Require `running=0` **and** `ok+fail >= 15`.

The exception is failure. An early job such as `Build` starves everything behind it, so the set
never reaches 15. On 2026-08-13 FXA-13034 sat at `ok=8 fail=2 running=0` because `Build` failed
on a TS7030 error, and only 10 checks ever existed. Treat any `fail>0` with `running=0` as
settled.

**Every push resets the functional gate to `on_hold`.** The launcher approves it for the first
PR. After any fix push, the pass must approve it again.

### Stage 9: Human review

The ticket is `ai-fixme-done`, the PR is open and green, and the slot is free. A human reviews.

`done` is a **queue**, not a record. It must drain, or it stops meaning anything. On 2026-08-13
it held 13 tickets while only 9 needed review, because 4 had already merged.

Two automated things still happen here:

- **The drain check.** `$CTL drain` also carries the check rollup, so it catches a job that
  goes red *after* the reconcile. Nothing else re-reads a `done` ticket's checks. On 2026-08-25
  #21073 had been red for six days while the ready list still advertised it. Report it, never
  relabel it, and read the failing job's log before blaming the PR. That one was an l10n workflow
  whose token lacked org team read scope.
- **The feedback sweep.** See §8. A reviewer's finding can send the ticket back to stage 3, at
  most twice.

### Stage 10: Drain

`$CTL drain` prints one line per `done` key that needs attention. `MERGED` takes
`label <KEY> merged`. `CLOSED` takes `label <KEY> rejected`. A green, still-open PR prints
nothing, and one `gh pr list` call covers every ticket.

**Never file a CLOSED PR as `merged`.** A closed PR is work a reviewer read and threw away, and
the label is the only place that outcome is recorded. Collapsing both into `merged` makes the
archive claim the pipeline landed something it did not, and it hides the one signal worth
auditing: which tickets produce PRs people reject.

A `KEY none -` line means the branch has no PR at all. Do not relabel it. That is a bug
somewhere, not a merge.

No Jira comment for a drain. The merge is visible on the PR.

## 3.3 Exit paths

Every ticket leaves the lifecycle through one of six doors.

| Exit | Label | Reached from | Reversible? |
|---|---|---|---|
| Merged | `ai-fixme-merged` | Stage 10 | Terminal |
| Closed unmerged | `ai-fixme-rejected` | Stage 10 | Terminal |
| Blocked | `ai-fixme-blocked` | Stage 8 caps, or the feedback cap | By a human, who relabels |
| Skipped | `ai-fixme`, unchanged | Stage 2 | Yes. A reporter's answer changes the fingerprint and the next pass re-grounds it. |
| Returned to queue | `ai-fixme` | Stage 8, `nolog` | Yes, automatically |
| Recommended for closing | `ai-fixme` | Stage 2, already fixed on `main` | A human closes the ticket |

The last one is a real result, not a failed pass. When the code already satisfies the ticket, do
not launch it. Report it for closing, with the evidence.

## 3.4 Where the time goes

```
  label ──▶ queued ──────────────────────▶ admitted
            ▲                                  │
            │ skip (fingerprinted)             │  1-3 min grounding
            └──────────────────────────────────┤
                                               ▼
                                      launch + boot   ~2 min
                                               │
                                               ▼
                                      agent run      10-20 min
                                               │
                                               ▼
                                      push + PR      ~1 min
                                               │
                                               ▼   ◀── VM reclaimed here
                                      CI settle      20-40 min
                                               │
                                               ▼
                                      human review   hours to DAYS  ◀── bottleneck
                                               │
                                               ▼
                                      merged / rejected
```

Stage 1 dominates when the pool is full or the crons are unarmed. Stage 9 dominates otherwise.
Nothing in the automated path is worth optimising until review throughput moves.

---

# 4. State machine

**The Jira label is the only durable state.** Nothing else is authoritative. Local files hold
counters and caches, and every one of them can be deleted without losing the pipeline's
position.

```
  ai-fixme                        queued, owns no slot
     |
     |  \__ admission skip: stays ai-fixme, label untouched
     |
     |  pass claims a slot and launches
     v
  ai-fixme-inflight               *** OWNS A POOL SLOT ***
     |
     |  \__ relaunch after a real CI failure: stays inflight
     |  \__ orphaned label, progress reports nolog: back to ai-fixme
     |  \__ attempt or relaunch cap reached: -> ai-fixme-blocked
     |
     |  PR open and green
     v
  ai-fixme-done                   review queue, slot released
     |
     |  \__ verified review feedback, max 2 rounds: -> ai-fixme-inflight
     |  \__ feedback cap reached: -> ai-fixme-blocked
     |
     |  drain
     +--> ai-fixme-merged         terminal archive
     +--> ai-fixme-rejected       terminal archive

  ai-fixme-blocked --> ai-fixme   only a human relabels
```

Only the `inflight` state owns a pool slot. Every transition out of it reaps the VM, because
`$CTL label` calls `reap` itself rather than trusting a pass to remember.

| Label | Meaning | Owns a slot? |
|---|---|---|
| `ai-fixme` | Queued. A pass may pick it up. | No |
| `ai-fixme-inflight` | Agent running, or PR open and CI not green. | **Yes** |
| `ai-fixme-done` | PR open, CI green, awaiting human review. | No |
| `ai-fixme-merged` | PR merged. Archive. | No |
| `ai-fixme-rejected` | PR closed unmerged. Archive. | No |
| `ai-fixme-blocked` | Needs a human decision. | No |

Three rules govern the labels:

1. The queue label is bare `ai-fixme`. Only the lifecycle states take a suffix, so the JQL exact
   match on `ai-fixme` does not also catch `ai-fixme-inflight`.
2. `$CTL label <KEY> <state>` performs the swap. It removes every other label in the family,
   so a ticket can never hold two states. It also reaps the VM on any transition out of
   `inflight`.
3. Do not use Jira status transitions for state, and do not invent a parallel scheme.

---

# 5. One pass

A pass is the unit of work that moves tickets between stages. It is idempotent, so running it
every hour is safe.

```
  0. lock            $CTL lock. If it prints `locked`, stop and say so.
  1. ground          cd into the fxa checkout, git fetch origin main.
  2. reconcile       For each `inflight` key, apply the stage 8 table.
  3. drain           $CTL drain. Stage 10.
  4. reapstray       Stop every VM whose ticket is not `inflight`.
  5. fill a slot     freeslots -> oldest launchable key -> stages 2 and 3.
                     ONE launch per pass, whatever the slot count.
  6. feedback sweep  For each `done` key, $CTL feedback <KEY>. §8.
  7. report          The table. Notify only on a new ready or a new block.
  8. unlock          Even if the pass did nothing.
```

Order matters in two places. Reconcile runs before the fill, so a ticket that turns green frees
its slot inside the same pass. `reapstray` runs before the fill, so `freeslots` sees the pool
after collection rather than before.

`reapstray` exists because `label` only reaps on a transition it performs. It catches everything
else: a pass that died between the launch and the reconcile, a label edited by hand, or a run
that finished with no pass after it.

## The output surface

A pass may write exactly six things. Everything else is out of scope, including Slack posts,
Jira status transitions, and release advice.

1. The Jira label, through `$CTL label`.
2. One Jira comment per state change, led with 🤖.
3. One PR comment when a ticket becomes `blocked`.
4. The report in the session.
5. One Jira comment on an admission skip, and only when `$CTL skip` prints `comment`.
6. One 👍 reaction per review comment the round actually fixed.

Number 5 matters even though a skip changes no label. The session report reaches only the person
watching that terminal, and an unattended pass has no such person. A finding that reaches nobody
is the same as no finding.

## The admission rules

Skip a ticket when any of these hold:

- It states no acceptance criteria you can name.
- It spans more than one train.
- It deletes or migrates production data.
- It adds a DB migration patch, or changes a published package surface.
- It needs a decision you would escalate to a person.

Separate two skips that look alike. **Underspecified** means nobody decided what "done" is, and a
reporter's comment fixes it. **Blocked** means the ticket is clear and something else stops the
work, such as a frozen path or a missing credential. Say which one you mean, because they do not
have the same remedy.

Two refinements that came from real misses:

- **Named implementation steps are a strong signal, even across many files.** Width is not what
  makes a run fail. FXA-13034 changed 26 files and shipped. FXA-14150 changed 13 and failed,
  because the instruction was wrong. Weigh a ticket by how much it makes the agent invent.
- **An unverifiable acceptance criterion is a carve-out, not a skip.** Implement the rest and
  make the PR say plainly what was not verified. Skip only when the unverifiable part *is* the
  change.

---

# 6. Scheduling

## The loop is session-only today

Claude Code cron jobs live in the scheduler's memory. They write nothing to disk. Three events
destroy them:

1. The operator closes the session.
2. Claude exits.
3. Seven days pass, and the job deletes itself after one last firing.

The pipeline state survives all three, because the state is the Jira label. Only the timer is
lost. A new session picks up in-flight tickets correctly on its first pass.

Two further limits apply. A job fires only when the REPL is idle, so a long turn delays a tick
without dropping it. Sleep stops every job, and nothing catches up on wake.

## Two loop designs exist, and they disagree

This is an open issue, not a design. `SCHEDULING.md` and the `fxa-automation` skill describe
different job pairs:

| Source | Job 1 | Job 2 |
|---|---|---|
| `fxa-ai-fixme/SCHEDULING.md` | `*/5 8-18 * * 1-5` cheap check-in that escalates | `7 8-18 * * 1-5` full pass, as backstop |
| `fxa-automation/SKILL.md` | `9,29,49 * * * *` full pass | `23 9,13,17 * * 1-5` read-only escalation triage |

A team picking this up must choose one and delete the other. `SCHEDULING.md` itself warns about
exactly this divergence, which means a wrong pair has already been armed once.

## Why the cheap check-in exists

An idle tick is not free. Each tick re-reads the accumulated session transcript, so cost tracks
context size rather than work done. Cache read and cache write dominate, and output tokens are a
small fraction. The same no-op report therefore gets steadily more expensive the longer a session
stays open.

An unattended overnight window is the worst case. It repeats one `idle, all queued skipped` line
for hours and launches nothing, and it cannot do otherwise: the queue moves only when a human
merges a PR, closes a ticket, or answers a question.

Two guards follow, and both matter:

- **The active-hours window.** Put it in the cron expression, not in prose, because the
  expression is the only part a later session copies.
- **The skip list.** Escalate only when the queue holds at least one key that `$CTL skipped`
  does not list. A non-empty queue is not the same as launchable work.

## Escalation rules for the check-in

The check-in observes and escalates. It makes exactly one write, which is reclaiming an idle VM
at stage 8. Four signals matter, and each has a trap behind it.

| Signal | Escalate? | The trap |
|---|---|---|
| No PR, `alive` DEAD, stage `watching` | Yes | Stage `starting` also reads DEAD. The VM is mid-boot and healthy. Gate on the stage word. |
| PR open, `running=0`, `ok+fail >= 15` | Yes | `running=0` also means "not started yet". |
| PR open, `running=0`, `fail>0`, any count | Yes | An early job failing starves the rest, so the set never reaches 15. |
| `freeslots` non-empty, one queued key not skipped | Yes | Do not require `inflight` to be empty. That was a one-slot assumption and it idled the second slot for up to an hour at a time. |

**Ignore the elapsed counter from `progress`.** macOS block-buffers the launcher's stdout when it
runs without a TTY, so the counter freezes during healthy runs. On 2026-08-12 it read
`watching 180s` for 11 minutes. Use changed-file count and commit count instead.

## The durable alternative

A macOS LaunchAgent running `claude -p "/fxa-ai-fixme"` removes every session limit. Each tick
reads a small prompt instead of a growing transcript, so cost stays flat and the pass can run
around the clock. Two risks need an answer first:

1. An unattended pass cannot ask for permission. It needs `--dangerously-skip-permissions` or an
   explicit `--allowedTools` list.
2. `finish_push_and_pr` signs the squashed commit on the host. A LaunchAgent may not reach an
   unlocked signing key. Test that step in the LaunchAgent environment before you switch.

---

# 7. The worktree pool

The pool is the concurrency limit and the trickiest part of the system.

The pool is discovered, not declared: every git worktree named `fxa-auto` or `fxa-auto-<n>`
beside the FxA checkout is a slot. Each slot is a git worktree of the FxA monorepo, cut
from `origin/main`. Reusing worktrees keeps `node_modules` warm; a brand-new slot pays a 5 to 10
minute install on its first run. Each running slot costs 4 vCPU, 8GB RAM, and 8 to 13GB of disk.

**A worktree holds one branch.** A relaunch after a CI failure needs that ticket's branch checked
out. So a ticket owns its slot from stage 3 until its label leaves `inflight` at stage 9, even
though the VM is stopped back at stage 8.

That gap produces the single most important distinction in the codebase:

| Command | Question it answers | Use it for |
|---|---|---|
| `$CTL slots` | Is a VM running here? | Diagnostics |
| `$CTL freeslots` | Is this slot claimable? | **Picking a slot. Always.** |

`freeslots` requires both conditions: the checked-out branch belongs to no `inflight` ticket,
**and** no agent VM is running on it. The second is not redundant. A ticket that leaves
`inflight` releases its label while its VM may still be up, and `worktree_prepare_for_issue`
refuses to mount a workspace another VM already holds. Reporting such a slot as claimable makes a
pass burn its launch on a guaranteed abort, which is what happened to FXA-14371 on 2026-08-24.

**Reaping is mandatory, and it hangs off the label write.** A finished agent sits at its prompt
at 0% CPU and holds 8 to 13GB indefinitely. With two slots the pool deadlocks after two launches.
On 2026-08-24 two VMs idled for four hours and eight consecutive passes did nothing.
`$CTL label` calls `reap` on every transition out of `inflight`, so a cron-fired pass cannot
forget it. Set `FXA_NO_REAP=1` to keep one alive for debugging.

Disk is the binding limit, not CPU. The host filled to 99% on 2026-08-11 and needed a manual 19GB
cleanup. Do not raise `FXA_MIN_FREE_GB` to force a launch through.

---

# 8. Review feedback, the loop back into stage 3

`done` means green. It does not mean correct. A reviewer, human or bot, can land a finding that
invalidates the PR. On 2026-08-14 Copilot found that #21038 recorded `account.login` as verified
before TOTP completed, on two routes, and the ticket sat in `done` regardless.

`$CTL feedback <KEY>` lists unhandled review comments. It drops comments whose `position` is
`null`, because those sit on a diff hunk a later push replaced, and it tracks handled comments by
ID so an edited comment cannot resurrect itself.

Four rules that cost real time when broken:

- **Count with `jq`, never with `wc -l`.** The output is JSON, and an empty result is four lines.
  On 2026-08-18 a line count read as "4 unhandled comments" on all 14 `done` tickets at once,
  twice in one session. A uniform non-zero count across unrelated PRs is the signature.
- **Verify before you believe.** A review comment is a claim. Ground it against `origin/main`
  exactly as you ground a ticket. A fix built on a wrong claim is a confident change to correct
  code.
- **Do not relabel on detection.** A ticket with feedback drops out of the ready list and shows
  as "feedback pending" while its label stays `done`. Flipping it to `inflight` immediately
  breaks slot accounting, because `inflight` means "owns a worktree". Three such tickets with no
  VM running makes every slot look owned and the pipeline stops launching.
- **Wait for a genuinely free slot.** A `done` ticket already released its worktree, so another
  branch is probably checked out.

Act when the fix is determinate and stays inside the ticket's scope. Report when the comment asks
a question, states a design preference, widens scope, or fails verification. The fix commit must
be strictly narrower than the original.

Stay silent on the PR. Do not reply to review comments and do not resolve threads. React 👍 to
each comment the round actually fixed, and never to one it declined. Record the IDs at launch
with `feedback <KEY> acted <id>...`; `label <KEY> done` fires the reactions once the fix is green.

Cap: **2 rounds per PR**, then `blocked`. Copilot re-reviews on every push, so without the cap
this never ends.

---

# 9. Caps and guardrails

Every cap below is a rule, not advice. Reaching one is a successful outcome. An honest `blocked`
beats a fourth 40 minute guess.

| Cap | Value | Stage | Why |
|---|---|---|---|
| Launches per pass | 1 | 3 | A bad context file cannot burn both slots. |
| Grounding tool calls | 10, plus 3 for Figma | 2 | The VM agent does the deep work. |
| Free disk before a launch | 25GB | 3 | A running clone takes 8 to 13GB. |
| `/goal` directive length | 4100 raw chars | 4 | Over the limit, the agent runs with no goal. |
| Agent turns | 30 | 6 | The `/goal` evaluator's cap. |
| Single verification step | 10 minutes | 6 | CI covers the rest. |
| CI reruns per head SHA | 2 | 8 | Then it is a real failure, not a flake. |
| Real fix attempts per ticket | 2 | 8 | Then `blocked`. |
| Relaunches for a dead VM | 1 | 8 | Then `blocked`. |
| Review feedback rounds per PR | 2 | 9 | The bot always has more to say. |

Hard prohibitions:

- Never merge, approve, or enable auto-merge. `gh pr merge --auto` is not an exception, even when
  a human approval is a required check.
- Never weaken, skip, or delete a test to reach green. Ignoring a file to satisfy an assertion
  counts as weakening it.
- Never launch without `--worktree <slot>`.
- Never put a secret, token, real email address, or phone number in a context file, a Jira
  comment, or PR text.

---

# 10. Durable state on disk

Everything under `~/.claude/state/fxa-ai-fixme/` is a cache or a counter. Deleting the directory
loses attempt counters and skip fingerprints, and loses nothing else. The Jira label carries the
position.

| File | Holds | Consequence if lost |
|---|---|---|
| `<KEY>.launch.log` | The launcher's full output | `progress` reports `nolog`, and the pass returns the ticket to the queue |
| `<KEY>.attempts` | Real-fix counter | The 2-attempt cap resets |
| `<KEY>.skipped` | Skip fingerprint, pass count, reason | The ticket gets one more skip comment |
| `<KEY>.feedback-seen` | Handled review comment IDs | Handled comments reappear as new |
| `<KEY>.feedback-rounds` | Round counter | The 2-round cap resets |
| `<KEY>.feedback-acted` | IDs this round will fix | The 👍 reactions are lost |
| `reporters.tsv` | Jira displayName to GitHub login | PRs get the team review only |
| `lock` | One pass at a time | A manual pass can race the cron |

The counters were originally under `TMPDIR`. macOS purges `/var/folders`, so they silently reset
to zero and the caps stopped protecting anything with no visible sign. Keep them under `~`.

`reporters.tsv` keys on **displayName**, not email. The local part of an address does not predict
the handle: `lzugai` is `LZoog`, `wclouser` is `clouserw`. An unmapped reporter resolves to
nothing, which is the safe direction.

Run telemetry goes to `agent-runs.jsonl` and `agent-costs.json` in the pipeline state directory (mirrored to Cloud Storage; `ai/docs/` in the FxA repo keeps symlinks), formerly inside the FxA
checkout, which is gitignored. `usage` must run before `stop`, because the token counts live
inside the VM.

---

# 11. Picking this up: what is hardcoded

A team adopting this pipeline must change or re-home each item below.

## One file to edit

Everything repo-specific is in `pipelines/fxa-ai-fixme.conf`. Copy it, change the values, and
select it with `fxa-sandbox-ctl --pipeline <name>`.

| Setting | Note |
|---|---|
| `PIPE_REPO_SLUG="mozilla/fxa"` | Every `gh` call targets it |
| `PIPE_REPO=~/Desktop/working2/fxa` | The checkout the pool is cut from |
| `PIPE_LABEL_PREFIX="ai-fixme"` | The label family, which IS the state machine |
| `PIPE_QUEUE_JQL` | What enters stage 1 |
| `PIPE_STATE_DIR` | Attempt counters, skip fingerprints, launch logs, the pass lock |
| `PIPE_RUNS_FILE`, `PIPE_COSTS_FILE` | Telemetry, in the FxA checkout's gitignored `ai/` |
| `PIPE_MIN_FREE_GB=25` | Disk floor for a launch |

Every one is overridable by its old environment variable (`FXA_REPO`, `FXA_FIXME_STATE`,
`FXA_FIXME_RUNS`, `FXA_FIXME_COSTS`, `FXA_MIN_FREE_GB`), so a one-off run needs no edit.

The pool is not in the config. It is discovered from the git worktrees on disk, so adding a
slot means adding a worktree and nothing else.

## Platform assumptions

- **The pass logic is version controlled here.** `skills/fxa-ai-fixme/` holds `SKILL.md` and
  `SCHEDULING.md`; `~/.claude/skills/fxa-ai-fixme` is a symlink to it. The `fxa-automation`
  skill, which holds the two cron definitions, is still unversioned in `~/.claude/skills/`.
- **Apple Silicon macOS only.** `tart` runs ARM64 VMs under the Virtualization framework.
- Notifications use `osascript`.
- The prompt reaches the agent through a `screen` paste, which depends on the TUI having drawn.
- The CircleCI token is read from `~/.circleci/cli.yml` when the env var is unset.
- Jira access goes through the `acli` CLI, not the REST API.

## Extending to another Jira project

The queue is label-driven, not project-driven. `$CTL queue` runs
`labels = "ai-fixme" AND statusCategory != Done` with no project clause, so a ticket in any
project enters stage 1 as soon as it carries the label.

One thing then needs attention:

**The repository.** `PIPE_REPO_SLUG` is fixed per pipeline. A project whose work lands in a
different repo needs its own `pipelines/*.conf`, not just a label.

Branch naming used to be the other one. There were two generators: `worktree_branch_for` in this
repo lowercased the key, and the skill's `branch_for` also prefixed `fxa-`. They agreed on FXA
keys and disagreed on every other project, so the skill looked for `fxa-pay-1234` while the
orchestrator had created `pay-1234`. Eight readers would have missed the run. There is now one
generator, `worktree_branch_for`, and the branch is the lowercased key and nothing else, so
`worktree_key_for` is a plain uppercase and the round trip holds for any project.

---

# 12. Known gaps

These are real and unresolved. Do not treat them as solved.

(Two earlier gaps are closed: the pass logic is version controlled, and the duplicate branch
naming is gone. See §11.)

1. **The two scheduling designs conflict.** See §6. Pick one.
2. **The loop is session-only.** It dies with the session and expires after seven days. The
   LaunchAgent path is designed but not built.
3. **`fxa-sandbox-ctl list` misreports status.** It tracks the `screen` session, not the agent.
   Claude Code can exit while `exec bash` keeps the session alive, so a dead agent reads as
   `running` for hours. Always confirm with `fxa-sandbox-ctl alive <KEY>`, which checks for a
   real `claude` process over SSH. Both now live in the same tool, so `list` should learn to
   call it.
4. **The launcher's elapsed counter freezes.** macOS block-buffers its stdout without a TTY. It
   is not a freshness signal.
5. **`from_failed` reruns break on a stale workflow.** Rerunning a week-old workflow restores an
   expired cache and dies in "Run DB migrations" before any test runs. Zero test results is the
   signature. Use a full rerun, then re-approve the gate.
6. **Figma designs enter only at stage 2.** The VM has no MCP, and the trigger reads only the
   description and comments. A design linked from an attachment, a Confluence page, or a Slack
   thread is missed.
7. **Review throughput is the bottleneck.** Stage 9 is where the pipeline actually queues.
   Optimising stages 2 to 8 moves nothing until that changes.

---

# 13. Quick reference

```bash
CTL=~/Desktop/working2/fxa-sandbox-ctl/fxa-sandbox-ctl

# Where is everything?
$CTL queue                 # stage 1: keys labelled ai-fixme, oldest first
$CTL skipped               # stage 1: which of those are NOT launchable
$CTL inflight              # stages 3-8
$CTL freeslots             # claimable slots -- use this, not `slots`

# What is one ticket doing?
$CTL progress <KEY>        # stages 4-7, from the launcher log. Read this FIRST.
$CTL alive <KEY>           # stage 6: real claude process over SSH
$CTL prstate <KEY>         # stage 8: PR number, state, check tally
$CTL feedback <KEY>        # stage 9: unhandled review comments
$CTL drain                 # stage 10: done keys needing action

# Writes
$CTL label <KEY> <state>   # the only state write; reaps the VM too
$CTL launch <KEY> <slot> <ctx>
$CTL skip <KEY> "<reason>"
$CTL lock / unlock
```

Read next:

- `README.md` for `fxa-sandbox-ctl` itself, its commands, and its security model.
- `VM_AGENT_GUIDE.md` for the environment inside the VM and the full stage 6 contract.
- `skills/fxa-ai-fixme/SKILL.md` for the pass rules, with the incident that produced each one.
  It is the same file as `~/.claude/skills/fxa-ai-fixme/SKILL.md`, through a symlink.
