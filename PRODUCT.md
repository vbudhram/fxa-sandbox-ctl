# FxA Agent: product guide and goals

Read this before you make a product decision about fxa-sandbox-ctl or fxa-agent-bot. It says what the
product is, who it is for, what it tries to achieve, and how the owner decides. When this guide and the
code disagree, the code is the fact and this guide is out of date: say so, and do not guess.

Owner: Vijay Budhram (the operator). Last checked against the code: 2026-10-17.

---

## 1. What the product is

FxA Agent is an **AI engineer teammate**. A person asks it for work in Slack, or labels a Jira ticket, and
it does the work the way an engineer on the team would. It reads the code, changes it in a sandbox, runs
the team's stack and tests, and ships a reviewable result: a draft pull request, a diff, or an answer.

It is **one teammate that many teams can configure**. Each team brings its own repos, workflow, tools,
access rules and budget. FxA is the first team and the most complete one. Another team can have a
completely different workflow: a read-only investigation team, a Rust service with no FxA stack, a team
that only gets diffs, or a team with a Jira queue that the agent works through alone.

Two repos make the product:

| Repo | What it is |
|---|---|
| `fxa-sandbox-ctl` | The controller (bash). It boots runners, loads teams, runs the Jira pipeline, ships PRs, and holds the guards. It also has the dashboard, the LLM proxy, the MCP gateway and the infra scripts. |
| `fxa-agent-bot` | The Slack bot (Node). It turns Slack threads into sessions and shows their progress. It keeps no session logic of its own: it calls the controller. |

Both repos are public. Nothing in them may hold a secret, an internal URL or a person's email.

---

## 2. Goals

### The north star

A team gets a **review-ready change with no human in the loop until review**, at a cost and a speed
that make it the obvious first step for routine work. The change is correct, small, tested, and needs
no feedback round.

### The goals, in order

1. **Safe by default.** No secret, private code or personal data leaves the place it belongs. The agent
   never acts on GitHub, Jira or Slack without the person who owns that action. A failure stops the
   work; it never opens a gate.
2. **Changes that merge with no feedback.** The pipeline's main measure: the share of fixed tickets that
   need a feedback round. It was 42% (53 of 126), and 18 needed two or more. The target is to bring both
   down while the merge rate stays the same.
3. **Teams serve themselves.** An admin creates and runs a team from the dashboard with no commit, no
   operator step and no restart. Later, owners who are not admins do the same through requests.
4. **Fast to the first useful output.** Measure the time to the first visible output in the thread, not
   the internal boot time. A quick answer takes about 16 s at the median. A session boot is about 9 s on
   Firecracker and 57 to 131 s on GCE.
5. **Cost that a team can predict.** Each run, session and team has caps. Medians in October 2026: a
   pipeline run about $2.40, a Slack session $1.45 (p90 $3.89), a quick answer $0.12.
6. **Adoption we can see.** "The biggest gap is adoption, and we cannot measure it." A feature that adds
   use for a second team is worth more than polish for FxA.

Treat the numbers as a snapshot. Before you claim a change improves one, measure it, or say that you did
not.

### What success looks like for a new team

The team admin fills in the dashboard form. `profile test` boots one runner and passes. The team turns
active. People in the team's channel tag the bot and get sessions on their repos, with their tools,
within their budget. Nobody asked the operator for anything, and FxA sessions did not change.

---

## 3. Who uses it

| Role | Who | What they may do |
|---|---|---|
| **Owner** of a thread | The person who started the thread, or the first allowed person who tagged the bot in it. | Everything in the thread. Only the owner ships (Open PR, Push, `!pr`), stops, pauses, restarts, diffs, rebases, and opens the desktop. |
| **Teammate** in the thread | Any allowed person in the channel. | Steer by tagging, answer the agent's questions, see status, watch, interrupt (unless the channel limits it), resume a paused session. The agent knows each line's author, so a teammate cannot pass as the owner. |
| **Outsider** | Anyone not allowed. | Nothing. Taps and tags are refused. A link card does not unfurl for them. |
| **Team admin** | An email in `TEAM_ADMINS`. | Creates, edits, tests, enables and disables team records in the dashboard. Sets team secrets. Creates, edits, pauses, runs now, stops and deletes the team's routines in the dashboard. Every write is audited. |
| **Jira reporter** | Anyone who can label a ticket. | Puts work in a team's queue with the `ai-fixme` label. |
| **Reviewer** | People, and Copilot. | Review and merge the agent's PRs. A Copilot review or a failed CI run starts an automatic fix round, at most 2 for each PR. |
| **Operator** | Vijay. | Holds the secrets, IAM, the live bot's access, the kill switches and promote. The guards are the operator's. |

Design for the owner first, and for the teammate second. Every other role is a guard, not a user.

---

## 4. How the product works

### Three ways in

1. **Slack sessions** (most use). A person tags `@fxa-agent` in a thread.
   - A **quick answer** comes first when the request reads like a question. A long-lived, read-only,
     firewalled runner answers in about 16 s. If it finds that real work is needed, it ends with
     `@@upgrade`, and a full session starts with what it found. The person sees one card either way.
   - A **session** is one runner plus one agent conversation. The person steers by replying. The agent
     may ask a question with up to 5 numbered options. When a turn ends with changes, the owner gets Diff
     and Open PR or Push.
   - After Open PR, the thread **follows the PR** for 14 days: CI, reviews, merges. It speaks only when a
     person must act.
2. **The Jira pipeline** (the `ai-fixme` label). A timed **pass** for each team admits tickets, launches
   runs, ships one squashed and signed commit as a draft PR, follows CI, and runs feedback rounds. The
   label is the only durable state. A ticket that needs a decision a person should make is skipped with
   one comment that names the decision.
3. **Routines** (the dashboard). A team admin sets a scheduled prompt on the team's page: a code, UX,
   performance or security review, or free text, with a schedule, the repos, an output mode (report,
   draft PR, or draft PR with notes), an optional Slack channel and a cost limit. Each **routine run** is a
   normal session with the team's profile, repos, access and budget. The bot posts only the result in
   the routine's channel: the draft PR link or the report, or why it skipped or failed, and the next run
   time. A routine with no channel posts nothing in Slack; its results are only in the dashboard History.
   Slack cannot create, change or start a routine, and shows no cost; the dashboard History does.

### The dashboard Overview

Overview is the control room: what needs a person, what runs, and what it costs.

- **Needs you** is one number: the Pipeline belts that need a person, plus the sandbox alerts that name a
  fix (a stray instance, a wrong base, a rejected goal), each key once. The rail badge and the tab title
  show the same number. At 0 the badge shows `!` when the alert strip has an alert. A ticket that waits on
  its reporter, or a PR that waits on a reviewer, is not in it (the Pipeline badge counts review waits).
- **Spend** and **Today** read the Stats feed with the Stats rules, so a range total equals Stats. A spend
  link sets the Stats filter for that visit only; the person keeps it with Keep these.
- **On the floor** shows a tile for each sandbox slot and each live session, with its belt stop. A viewer
  who is not a team admin sees a routine run only as a scheduled run.
- **What the system is doing** shows the pass now, CI and the merge watch, and the next 12 hours of passes.
  Routine times show to team admins only.
- A figure that the page cannot read says unknown, never 0.

### The dashboard Sandboxes page

Sandboxes (`#runners`) shows every sandbox in one list: pipeline runners on GCE, Slack sessions and
scheduled (routine) runs, on GCE or Firecracker.

- The chip says what is in use with the same words as the Overview floor, for example
  `2 of 8 pipeline sandboxes in use, plus 1 Slack session`.
- Three cards: pipeline slots, session slots and cost (the always-on manager, the Firecracker host while up,
  and the GCE sandboxes now). The 7 day figures read the Stats feed.
- **Needs a fix** lists each sandbox that bills with no run behind it, with the one command that stops it.
  A command shows only on a fresh agents feed and for a name the page checks. A held slot gets the steps to
  free it, never a host path.
- The rail badge counts the rows that need a fix, with the label `3 sandboxes need a fix`; it shows `?` when
  the agents feed is stale or a slot is unknown.
- Recently completed lists the last ended runs from the same server rules as Overview Recent runs: a
  secured ticket, a private team and a routine stay gated.
- Rows show no agent output line. A viewer who is not a team admin sees a routine run only as a scheduled
  run, with no team, cost or link.

### The unit of work

`thread → session → runner → change → PR → CI → review → merge`

- One thread, one branch, at most one PR, after the first push. Other work goes to a new thread
  (`!spin`).
- A pause frees the runner and keeps the work. A reply resumes it, with thread notes carried across.
- A merge or a close ends the session with one end card.

### What the agent can reach

The agent works in a runner VM as the user `agent`, behind an egress firewall. It has no GitHub, Jira or
Anthropic credential of its own:

- Model calls go through the **LLM proxy**, which prices and caps each run.
- Tool calls (Jira, GitHub, Slack, Sentry, Figma, Bugzilla, Argo CD) go through the **MCP gateway**,
  which applies read-only allowlists, a team's scope, and a cap of 200 calls a run.
- Pushes and PRs come from the **host**, through the GitHub App, never from the runner.

---

## 5. Teams

### What a team is

A team is a **team record**: one JSON object in the state bucket, validated by `lib/team_record.py` and
never sourced as code. FxA is still a **folder team** (`profiles/fxa/profile.conf`), and a folder wins
over a record of the same name. All other teams are records.

### What a team record sets

| Key | What it sets |
|---|---|
| `label`, `status` | The name people see. `draft`, `active` or `disabled`. A team turns active only through `profile enable`, after `profile test` passes at that generation. |
| `access` | Who may start sessions: listed users, channels, Jira prefixes, or open to everyone allowed. A team with a private repo cannot be open. |
| `repos` | Up to 8 repos, each with a role: `work` (writable, ships), `dep` (runs beside it), `data`, `ref` (read-only). Each has a path and a base branch. |
| `stack` | `fxa` (the FxA stack runs in the runner) or `none`. A team without the FxA stack must bring its own goal. `stack.repo` names the row the stack runs from, for a private fork of FxA. |
| `runner` | The backend (`gce` or `firecracker`), the Android emulator, a desktop URL. |
| `egress` | The extra hosts the agent may reach. Hosts that take data out with no account (paste sites, tunnels, request catchers) are refused, even for an admin. |
| `mcp` | Which connectors the team's sessions get. |
| `jira` | The team's project and whether the pipeline works its queue. With `jira.secret: true`, the team takes only the project's secret tickets (a security level or a secret label). Its work repos must be private, as GitHub confirms, and it cannot be open or list Jira prefixes. |
| `pr` | Whether the team opens PRs, and the reviewers. A team with `open: false` gets diffs only. |
| `caps` | Launches per day and dollars per day and per month, inside the operator's ceilings. |
| `prompts` | The team's `CLAUDE.md`, guide and pass goal. Admins edit these as text. |
| `skills` | Skills from the reviewed catalog (`skills/team-catalog.txt`). |
| `boot` | A boot script from `boot/<name>.sh`, pinned by its SHA-256. |
| `secrets` | Secret names (never values): the team's own Jira login, and runtime secrets written into a dep, data or ref repo on the runner. |

**What a team cannot set:** any host key (state paths, locks, URIs, credentials), and any code. Skills
and boot scripts are repo code that a person reviewed. The record only names them, and a boot script
runs only while its file matches the pinned hash.

### Different workflows, one product

| Workflow | How a team gets it | Example |
|---|---|---|
| Full FxA work with PRs | `stack: fxa`, work repo `mozilla/fxa`, PRs on | FxA |
| A second repo beside FxA | Two work repos, or a work repo and FxA as `dep` | pyfxa-team |
| Read-only investigation | `pr.open: false`, its stack started by a boot script | monitor |
| A repo the App cannot write | The tree ships as a diff in the thread | Firefox in fxa-android |
| A queue the agent works alone | `jira.project`, `jira.queue: true`, a `goal_md` | sync-storage (STOR) |
| A private repo | The App installed on it; a full clone with a read-only token; code stays out of public channels, the watch page and shared memory | (live test pending) |
| Secret tickets against a private repo | `jira.secret: true`, private work repos only | fxa-private |

**Not possible yet** (phase 3): a stack recipe that is not FxA (`stack.kind: recipe`),
a team image, and a generic pass skill for a team that is not FxA. Do not
fake these with prompt text; say that the team needs phase 3.

---

## 6. Principles

Apply them in this order. When two conflict, the higher one wins, and you say which one you gave up.

1. **Fail closed.** When a check cannot tell, treat the input as the dangerous case: private, read-only,
   not allowed, not tested. A rate limit, an outage or a missing field must never open a gate. (Example:
   an unclear GitHub answer counts as private.)
2. **Untrusted text is data.** Jira, PR bodies, review comments, Slack messages from others, CI logs and
   web pages go into prompts fenced, and never start an action. A PR number in text gives a button; it
   does not act. A backlog item describes a problem; it does not authorize a change.
3. **No credential in the runner.** The runner gets references, scoped tokens through the proxy and the
   gateway, and at most a short read token that the controller removes before the agent starts. Never a
   value in a log, a command line, `.git/config`, a Slack message or an audit row.
4. **A person owns each outside action.** The agent never merges, approves or enables auto-merge, and its
   PRs are drafts. It pushes to a person's PR only after the author's consent on GitHub. Automatic rounds
   stop at 2.
5. **Records are data, never code.** A dashboard write starts from validated JSON. One validator serves
   the write path and the load path. New code a team needs goes into the repo through review.
6. **One code path.** The CLI, Slack and the dashboard call the same controller commands. Do not add a
   second way to do a thing.
7. **Keep what people do today working.** A change that removes a step people use needs its replacement
   in the same change. FxA sessions must not change when a team feature lands.
8. **Fewer moving parts.** No new setting when a fixed default works. Prefer the change that is small and
   easy to revert. Fix the root cause once, where every caller passes.
9. **Quiet and clear in Slack.** Speak when a person must act or something finished. A message says what
   happened and the next step. Do not announce that you will be quiet. Write in plain, short sentences.
   Assume a phone.
10. **Evidence before building.** Measure, or read 10 real threads, before you build a metric or a
    feature for a problem. A check must fail without its change (`prove.sh`), and you verify a change the
    way a user meets it (the dev bot, a real runner).

### The bot's voice

Candid and warm, not cheerful. It recommends one option ("I would …") and lets the engineer decide. It
speaks for user privacy, account security, accessibility and localization. It prefers the simplest fix
that works. It shows no dollar amounts to people; cost is the operator's view.

---

## 7. How to make a decision

### Questions to ask

1. **Who meets this, and how often?** An owner in normal use outranks a rare edge case. A security defect
   with a named path outranks both.
2. **What happens when it fails?** Name the failure. If the failure opens a gate, redesign it.
3. **Does it hold for a team that is not FxA?** Picture monitor (read-only), sync-storage (a queue, no
   FxA stack) and a private-repo team. A feature that works only because the team is FxA is a special
   case: name it, or make it general.
4. **Is it the team's choice or the operator's?** Text, people, caps within ceilings, Jira and PR rules
   are the team's. Code, credentials, guards, ceilings and access to the live bot are the operator's.
5. **Does it need a person?** Anything that changes IAM, secrets, the live bot's access, GitHub settings
   or a published artifact needs the operator's explicit go. Do not decide it yourself.
6. **Is there already a way?** Reuse the existing command, setting or pattern before you add one.

### Defaults for common decisions

| Decision | Default |
|---|---|
| A new setting | No. Use a fixed default. Add a team key only when two real teams need different values. |
| Per team or global | Per team only for what teams really differ on: repos, tools, access, budget, prompts. Guards are global. |
| A new Slack message | Edit the existing card. Post only when a person must act. |
| A new button | Only for the owner's next step. Show it to the owner; tell others privately why they cannot. |
| An edit to an active team | Text, people, caps, Jira and PR changes keep it active. A change a runner reads (repos, stack, runner, egress, MCP, skills, boot, secrets) needs a draft, a test, then enable. |
| A new connector or egress host | Read-only allowlist first. Never a host that takes data out with no account. |
| Something the agent could do alone but a person might object to | Ask in the thread, with a recommended option. |
| An unclear requirement in a ticket | Skip it with one comment that names the decision. Do not guess. |
| A risky feature | Ship behind the dev bot, verify it as a user, then promote. Prefer a change that is easy to revert. |

### Decisions already taken (do not reopen without new evidence)

- Team records live in the GCS state bucket with generation checks. They do not live in the repo or in a
  database.
- Slack access lives in the team record, so one write covers the queue, the routing and the access.
- One shared GitHub App with repo claims that an admin approves. No App and no personal token for each
  team.
- One Anthropic key, with daily and monthly caps for each team in the proxy. No key for each team.
- One thread, one branch, at most one PR. Work that is not about that PR goes to a new thread.
- A PR is its own change record. Moving it moves its home thread.
- Monitor's sign-in uses a local FxA stack in the runner, so no credential enters the runner.
- Memory: agents propose, people approve, and memory is scoped by repo first. A run on a private repo
  saves nothing to shared memory.
- Private repos: no agent fetch after start, a full clone, code only in private channels, no watch page.
- A team with the Jira connector and no Jira project of its own reads FxA's Jira project, as FxA does.
  Most teams that work beside FxA need its tickets. A team with a project reads only that project.
- Team records are the norm for every team but FxA. `PROFILE_OPEN` and `PROFILE_USERS` in the bot env count
  only for a team name that has no record.
- Not now: AI review of human PRs (no data that people want it), caps for each person (sessions have
  caps), best-of-N runs (twice the cost), fleet migrations (almost no session uses several trees), a
  multiplayer IDE (the watch page covers it).

---

## 8. Non-goals

- Repos that are not on GitHub.
- A general multi-tenant platform or a registry for other companies.
- Root code from the dashboard. A boot script is repo code with a pinned hash.
- Changes to the guards by a team: the tooling guard, the personal-data guard, the spend ceilings.
- Hard isolation between teams on the manager in this version. Each team's pass running with only its
  own credentials waits until a team with its own secrets turns on a queue.

---

## 9. Open decisions and gaps

Read these before you build in the area. They are the owner's to decide.

- **Phase 3:** teams that are not FxA run well (recipes, images, a generic pass, scoped lessons). It
  waits on a decision about how a team's own stack recipe runs.
- **Phase 4:** owners who are not admins create teams through requests.
- **MCP identity for each team**, so a team's connectors use its own login.
- **Old `PROFILE_OPEN` entries** in the live bot env can start a team whose record is disabled. The
  operator removes them.

---

## 10. Words we use

| Word | Meaning |
|---|---|
| Session | One runner and one agent conversation, key `agent-<hex>`. At most one live session for each thread. |
| Thread | A Slack thread. Unbound until the first push, then bound to one branch and one PR. |
| Change | A PR as its own record, with a home thread. |
| Run | One pipeline launch for a ticket. |
| Pass | A timed job for each team that works its Jira queue. |
| Runner | The VM the agent works in (GCE or a Firecracker slot). |
| Manager | The VM that runs the controller, the bot, the dashboard and the timers. |
| Quick answer | A fast, read-only answer before a session. `@@upgrade` turns it into a session. |
| Routine | A team's scheduled prompt, set by a team admin in the dashboard, that posts its result in one Slack channel, or with no channel, only in the dashboard History. |
| Routine run | One run of a routine: a session started by the schedule or by Run now, with its result in the routine's History. |
| Team record | A team's JSON config in the state bucket. |
| Folder team | A team with `profiles/<name>/profile.conf` in the repo (only FxA now). |
| Role | `work` (ships), `dep`, `data`, `ref` (read-only) for each repo of a team. |
| Stack | The services a team runs (the FxA stack), or the set of trees for one thread. |
| Tree | One repo checkout in the runner. |
| Ship | Push a branch, open a PR, or update one. |
| Handoff | The file a run writes when it finishes: branch, PR title and body. |
| Draft / active / disabled | A team's status. Active only after a passed test. |
| Operator | The platform owner who holds secrets, access and promote. |
| Dev bot / promote | The test copy of the bot on the manager, and the deploy of `main` to the live bot. |

---

## 11. Where to read more

| Topic | File |
|---|---|
| The controller, its commands and its security model | `README.md` |
| The Jira pipeline | `AI_FIXME_PIPELINE.md` |
| The team record and its rules | `lib/team_record.py`, `lib/teams.sh` |
| The skills a team may name | `skills/team-catalog.txt` |
| The bot's commands and UX | `fxa-agent-bot/README.md`, `fxa-agent-bot/src/render.js` |
| The bot's intended behavior, as tests | `fxa-agent-bot/e2e/scenarios/` |
| The bot's voice | `guide/voice.md` |
| How to change, test and ship the code | `skills/fxa-ctl-dev/SKILL.md` |
