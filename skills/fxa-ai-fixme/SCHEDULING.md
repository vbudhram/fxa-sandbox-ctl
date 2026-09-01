# Scheduling the ai-fixme skill

This file records how the skill runs on a timer. The timer is not part of the skill. You must
start it in each new Claude session.

## Why you must restart it

Claude Code cron jobs are session-only. The scheduler holds them in memory. It writes nothing to
disk. Three events destroy them:

1. You close the session.
2. Claude exits.
3. Seven days pass. A recurring job fires one last time, then deletes itself.

The skill state survives all three, because the state lives in the Jira label and in
`~/.claude/state/fxa-ai-fixme/`. Only the timer is lost. A new session picks up in-flight tickets
correctly on its first pass.

## How to restart

Type this in a new session:

    Restore the ai-fixme crons from ~/.claude/skills/fxa-ai-fixme/SCHEDULING.md

Claude reads the two job definitions below and re-creates both. The job IDs change every time.
The IDs in this file are examples only.

## Active hours — 08:00 to 18:00, Monday to Friday

**Both cron expressions below carry this window. Arm them exactly as written.** The window is not
advice in a paragraph. It is in the expression, because the expression is the only part a later
session copies. An earlier version of this file stated a cadence in prose while
`fxa-automation/SKILL.md` stated a different one, and the wrong pair got armed.

**Why the window exists: an idle tick is not free.** On 2026-08-26 a 42 hour session with the two
jobs armed 24/7 cost $471.09. Output was $17.64 of that. The other $453 was cache read and cache
write, which bill for re-reading the conversation on every tick. Cost tracks context size, not
work, so an idle tick gets more expensive the longer the session runs: the same no-op report cost
about $5 in the third hour and about $15 in the thirteenth.

The overnight block from 21:00 to 13:00 spent roughly $150 to print 140 copies of
`ai-fixme: idle, 15 queued but all skipped`. It launched nothing. It could not: the queue moves
only when the operator merges a PR, closes a wrong ticket, or answers a design question, and none
of those happen at 03:00.

**To change the window, edit both expressions and nothing else.** The rest of this file is
independent of it.

**The window belongs to the session model only.** Under the LaunchAgent model at the end of this
file, each tick is a fresh `claude -p` that reads a small prompt instead of an accumulated
transcript, so the cost stays flat and the hourly pass can safely run 24/7. Re-read this section
before widening the window in a session.

## Job 1 — check-in, every 5 minutes during active hours

Cron expression: `*/5 8-18 * * 1-5`

This job observes the running agent. It escalates to a full pass only when it sees work to do.
A mid-run tick stays cheap. A finished run gets acted on within 5 minutes.

Use this prompt exactly:

```
FxA ai-fixme check-in. Observe, reclaim an idle VM, and escalate to a full pass ONLY when a pass can actually do something.

CTL=$HOME/Desktop/working2/fxa-sandbox-ctl/fxa-sandbox-ctl
WT=$HOME/Desktop/working2/fxa-auto

STEP 1 — observe (ONE bash call, no lock, no label writes).
Run `$CTL inflight`, `$CTL freeslots`, `$CTL queue`, and `$CTL skipped | cut -d' ' -f1` -- ALWAYS, all four, in the same call. A claimable slot matters even while another ticket is inflight, because the pool has two slots. If `inflight` prints nothing, go straight to STEP 3.
Otherwise for each inflight key gather:
- `$CTL alive <KEY>`      -- live claude process in the VM, or DEAD/no-vm
- `$CTL progress <KEY>`   -- STAGE ONLY: starting | watching | pushed | squashing | pr <url> | error | nolog
- `$CTL prstate <KEY>`    -- prints: KEY <pr|none> <state> ok=N fail=N running=N
- the pool worktrees: for fxa-auto and fxa-auto-2, `git -C <wt> status --short -- ':!*.fxa-auto-*' | wc -l`, `git -C <wt> log --oneline origin/main..HEAD | wc -l`, and `ls <wt>/.fxa-auto-done.json`

Read the STAGE word from `progress` but IGNORE its elapsed seconds. The launcher's stdout is block-buffered without a TTY, so the counter freezes and is NOT a freshness signal. Use files-touched and commits as forward motion.

STEP 2 — reclaim an idle VM. If `prstate` shows a PR AND `alive` reports alive, the agent has no work left: the launcher already pushed and opened the PR. The VM holds 4 vCPU and 8GB for nothing while CI runs. Run these three in order, then continue:
  $CTL tokens <KEY>     # MUST run before stop or the telemetry is lost for good
  $CTL record <KEY>
  $CTL stop <agent-name>    # agent name is the key lowercased, e.g. fxa-14339
This is the ONLY write this check-in may make. Do not label, comment, push, or launch.

STEP 3 — decide. Escalate by invoking the /fxa-ai-fixme skill (a full pass, which takes the lock) if ANY of these hold:
- no PR AND `alive` reports DEAD AND `progress` stage is `watching` -> the agent died mid-run
- no PR AND a handoff file exists -> the handoff landed but the push or PR may have failed
- a PR exists AND running=0 AND (ok+fail) >= 15 -> CI has genuinely SETTLED
- **a PR exists AND running=0 AND fail>0, at ANY check count -> SETTLED BY FAILURE, escalate.** An early job (Build, Init, Lint) failing starves every job behind it, so the set never reaches 15 and the rule above would wait forever. On 2026-08-13 FXA-13034 sat at `ok=8 fail=2 running=0` because `Build` failed on a TS7030 error; only 10 checks ever existed.
- `progress` stage is `error` or `nolog` -> the launcher failed, or the label is orphaned
- **`freeslots` prints at least one slot AND the queue contains at least one key that is NOT in the skip list -> a claimable slot with launchable work.** This holds even when another ticket IS inflight. Do not require `inflight` to be empty: that was a one-slot assumption from before the pool had two worktrees, and it left the second slot idle for up to an hour at a time. A pass still launches at most one ticket, so escalating here cannot overfill the pool.

Do NOT escalate in these cases, because a pass would only no-op or do harm:
- `progress` stage is `starting` -> the VM is MID-BOOT. Claude has not launched yet, so DEAD/no-vm is EXPECTED here. Escalating makes a pass read this as a failed launch and relaunch a healthy agent. Never escalate on DEAD while the stage is `starting`.
- `progress` stage is `pushed` or `squashing` -> the host is mid-handoff, leave it alone
- no PR, alive, no handoff, stage `watching` -> mid-run
- a PR exists AND running>0 -> CI still in flight, nothing to reconcile yet
- a PR exists AND running=0 AND **fail=0** BUT (ok+fail) < 15 -> NOT settled, still starting. running=0 also means "not started yet". A full FxA PR carries about 18 to 21 checks. Right after a push, or right after the functional gate is approved, only a handful exist and none are running yet. On 2026-08-12 FXA-14114 read `ok=9 fail=0 running=0` in that window while 7 gate-dependent jobs had not been created; a pass would have labelled it done with its key test never run.
- **`freeslots` prints nothing -> do NOT escalate for a launch.** Every slot is owned by an inflight ticket. Use `freeslots`, never `slots`: `slots` reports whether a VM is running, and the VM is stopped as soon as the PR opens, so a slot reads `free` for the whole CI run while its ticket still owns the worktree. Launching there switches the branch out from under a ticket that may still need a fix relaunch.
- **Every queued key IS in the skip list -> do NOT escalate.** Those tickets already failed admission and need a human decision. A pass would re-ground them, skip them again, and change nothing, every 5 minutes forever. Report "nothing launchable" and wait.

Key the DEAD check on BOTH "no PR" and stage `watching`. Once a PR is open, DEAD is expected, because STEP 2 stops the VM on purpose.

The hourly full pass is the backstop for anything these rules miss, such as CI that never settles or a `prstate` probe that failed transiently. Do not widen these rules to compensate for it.

STEP 4 — report ONE line per inflight ticket, and nothing else when not escalating:
  FXA-NNNNN | <stage> | alive|DEAD | Nfiles Ncommits | handoff yes|no | PR <tally or none>
Append " | VM reclaimed" when STEP 2 stopped a VM.
Append " | not settled (thin check set)" when running=0, fail=0, and (ok+fail) < 15.
When a slot is claimable and every queued key is in the skip list, report exactly:
  ai-fixme: idle, N queued but all skipped (awaiting your decision)
When inflight is empty and the queue is empty, report exactly: "ai-fixme: nothing in flight."
No preamble, no summary, no advice. If you escalated, report the pass result in the skill's normal table format instead.
```

## Job 2 — full pass, hourly during active hours

Cron expression: `7 8-18 * * 1-5`

Prompt: `/fxa-ai-fixme`

This job is the backstop. Job 1 handles the normal path, so job 2 exists for the states that job
1's four rules do not model:

- CI never settles. A check hangs with `running>0`, so job 1 never sees a settled PR and never
  escalates. Job 2 still runs the reconcile table and can rerun the workflow.
- A probe fails transiently. If `gh` rate-limits, `prstate` reads `none`, and job 1 wrongly
  concludes the ticket is mid-run. Job 2 re-reads every signal from scratch.
- An orphaned label. A pass that died mid-flight leaves a ticket `inflight` with `nolog`. The
  reconcile table returns it to the queue.

Keep job 2 even though job 1 escalates. Do not widen job 1's rules to cover these cases. Job 1
runs 12 times an hour, so a rule that fires too often costs 12 sessions instead of one.

The minute is 7, not 0. An off-minute spreads load and avoids the crowded hour boundary.

## Why the check-in reclaims the VM

The launcher pushes the branch and opens the PR. It does not stop the VM. The agent then sits idle
at a prompt and holds 4 vCPU and 8GB for the whole CI run, which takes 20 to 40 minutes.

The check-in stops that VM as soon as a PR exists. It captures `usage` first, because the token
counts live inside the VM and `stop` deletes them.

This creates one trap. The label stays `inflight` while CI runs, so `alive` reports DEAD for a
healthy ticket. An escalation rule of "DEAD means escalate" then fires on every tick. Key the DEAD
rule on "no PR" instead. Once a PR is open, DEAD is the expected state.

## Why the queue check needs a skip list

"The queue is not empty" is not the same as "the queue holds something launchable". A ticket that
fails the admission gate keeps its bare `ai-fixme` label on purpose, so it stays visible to a
human. It therefore stays in `$CTL queue` forever.

A rule of "queue non-empty means escalate" then fires every 5 minutes. Each pass re-grounds the
same tickets, skips them again, and changes nothing. On 2026-08-12 the queue held only FXA-14115 and
FXA-14324, both already skipped, and the loop would have run all night.

**The slot test is `freeslots`, not `inflight` being empty.** The original rule keyed on an empty
`inflight` because the pool had one worktree, so "nothing in flight" and "a slot is free" were the
same statement. With two slots they are not. On 2026-08-18 FXA-4894 was inflight and waiting on CI
while `fxa-auto-2` sat claimable, and the check-in declined to escalate for 5 ticks in a row. The
hourly pass is the only thing that would have used it, and cron fires only while the REPL is idle,
so in an active session that slot can go unused indefinitely.

The skip list is the durable memory that stops it. Read it with:

    $CTL skipped        # KEY <passes> <last> <reason>, one line per skipped ticket

Escalate only when the queue holds at least one key that command does not list.

`$CTL skip` writes one `<KEY>.skipped` file per ticket under
`~/.claude/state/fxa-ai-fixme/`, keyed by a hash of the whole ticket. An earlier version of this
file named a single `skipped.tsv` that nothing ever created, so the guard did not work and this
prompt read an empty list on every tick. Use the command, never a raw path.

**Remove a key from the file when its blocking question gets answered.** That is what puts the
ticket back in play. Nothing else reads the file, so a stale entry silently keeps a ticket parked.

## Why "settled" needs a check count, not just running=0

`running=0` has two meanings. CI finished, or CI has not started. Both look identical in
`prstate`.

Two events produce the second meaning:

1. A push. GitHub reports the few checks it has created so far.
2. An approval of the functional gate. The gate job flips to SUCCESS, and the jobs behind it do
   not exist yet.

A full FxA PR carries about 18 to 21 checks. On 2026-08-12, FXA-14114 read
`ok=9 fail=0 running=0` seconds after the gate was approved, while 7 gate-dependent jobs,
including the one that had been failing, had not been created. A pass in that window would have
labelled the ticket `done` with its key test never run.

Require `running=0` AND `(ok+fail) >= 15` before you treat CI as settled. `prstate` itself is
correct; it counts PENDING, IN_PROGRESS, and QUEUED. The gap is in the reading, not the tool.

## Why the DEAD check needs the stage word

`alive` reports `no-vm` for about the first minute after a launch. The VM boots, then the launcher
waits for the infrastructure services, and only then does it start Claude. No `claude` process
exists yet, so `no-vm` is correct and the run is healthy.

A rule of "no PR and DEAD means escalate" fires during that window. The pass then reads the
reconcile table, finds a dead VM, and relaunches a healthy agent. On 2026-08-12 FXA-14340 hit this
one minute after launch.

Gate the DEAD rule on the stage word from `progress`:

- `starting` means mid-boot. DEAD is expected. Never escalate.
- `watching` means the launcher polls for the handoff, so Claude did start. DEAD here is a real
  failure.

## Why the check-in ignores the elapsed counter

`$CTL progress` reads the last `[ Ns]` mark from the launcher log. The launcher writes a mark
every 30 seconds. macOS block-buffers the launcher's stdout when the launcher runs without a TTY,
so the marks stay in the buffer. On 2026-08-12 the counter read `watching 180s` for 11 minutes
during a healthy run.

Do not treat the counter as a freshness signal. Use these instead:

- `$CTL alive <KEY>` counts real `claude` processes over SSH.
- The count of changed files in the worktree.
- The count of commits ahead of `origin/main`.

## Limits you cannot remove in a session

- The session must stay open.
- A job fires only when the REPL is idle. A long turn delays a tick. It does not drop the tick.
- Sleep stops every job. Nothing catches up on wake, except the next scheduled tick.

## The durable alternative

A macOS LaunchAgent removes every limit above. It runs `claude -p "/fxa-ai-fixme"` on a timer. It
survives a session exit and a reboot.

The operator chose the session model on 2026-08-12, because the session reports progress directly.
Two risks need an answer before you switch:

1. An unattended pass cannot ask for permission. It needs `--dangerously-skip-permissions` or an
   explicit `--allowedTools` list.
2. `finish_push_and_pr` signs the squashed commit on the host. A LaunchAgent may not reach an
   unlocked signing key. Test the signing step in the LaunchAgent environment first.
