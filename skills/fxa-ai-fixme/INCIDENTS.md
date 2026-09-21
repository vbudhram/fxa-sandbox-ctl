# FxA ai-fixme: incident record

Why each rule in `SKILL.md` exists. Read the section that matches the situation in front of
you; do not read this file on a quiet pass. `SKILL.md` names the section beside each rule.

## Grounding

- **Working-tree grep (2026-08-11).** The local checkout sat on `main-tst2`, 1253 commits behind,
  so a grep reported a file as missing that exists on `main`. Ground against `origin/main` only.
- **Description-only grounding (2026-08-13, FXA-14325).** `acli jira workitem view` omits every
  comment with no error and no count. The reporter had answered both blocking questions in a
  comment before tagging the ticket; the skip argued against a decision they had made. The
  reporter then asked on the ticket whether the pipeline reads comments at all.
- **Stale tickets (2026-08-18, one pass):**
  - FXA-14271 was already fixed on `main`: the test asserted the href, `clickHelp` was gone, the
    code comment cited the same Fastly 429 reasoning. A launch would have produced an empty PR.
  - FXA-12182 claimed `session/status` returned only verified and uid. The route already returned
    `state`, `details`, and `sessionVerificationMethod`. One field was missing, not the feature.
  - FXA-6107 asked for `node-fetch` 3.x. `engines` is Node `^24.15.0` with global `fetch`, one
    production file imports it. The right fix is deletion, which the ticket never considered.
  - FXA-9095 read as a 280-file Chai upgrade. 224 files sit under `fxa-content-server/app/tests/`,
    which has no test script and no CI job.
- **Frozen twins (2026-08-13, FXA-14150).** A repo-wide grep found 13 files with a stale postal
  address. Six were frozen duplicates under `lib/senders/emails/layouts/`, byte-identical to the
  live `libs` copies. The context file made "all 13" an acceptance criterion, `check:frozen`
  rejected the commit, and the run ended in `error`: one launch and 25 minutes lost to a wrong
  instruction.
- **Phantom frozen entries (until 2026-08-18).** The skill table listed `test/local/.*`,
  `test/remote/.*_tests\.js$`, and `test/oauth/.*` as frozen after the repo had removed them.
  FXA-13670 in `test/scripts/` was nearly rejected on that basis. Read `check-frozen.ts` from
  `origin/main` every time.
- **Design linked from elsewhere (FXA-14345).** The Figma trigger reads only description and
  comments. This ticket pointed at a Slack thread. Known limit, left by choice.

## Admission

- **Underspecified vs blocked (FXA-14325).** Skipped while it read "Proposal (to discuss)",
  shipped once the reporter answered. A comment fixes underspecified; nothing but a human fixes
  blocked.
- **Wrong skip (2026-08-18, FXA-14365).** Five tractable steps, all files present, skipped because
  step 5 said "verify against a production build". One unverifiable step is a carve-out, not a
  reason to throw away four good ones.
- **Carve-out done right (FXA-14359).** Items 1 to 3 shipped, item 4 was a relier-facing contract
  change and the PR body said so.
- **Width is not the risk.** FXA-13034 changed 26 files and shipped. FXA-14150 changed 13 and
  failed, because the instruction was wrong.
- **Skip comments that reached nobody (2026-08-12, FXA-14115).** Skipped for a scope question, the
  reporter's own question from 7 July went unanswered, and the reasoning lived only in a local
  file. Hence the Jira skip comment.
- **Hand-maintained skip ledger.** An earlier rule asked the pass to keep
  `~/.claude/state/fxa-ai-fixme/skipped.tsv`. Nothing ever created or read it. `$CTL skip`
  replaced it because judgment does not survive a cron-fired pass with no memory.

## Verification budget

- **Over-verification (FXA-14299).** 45 of 58 minutes on `nx lint fxa-auth-server`, then
  `nx reset`, for a 9-line test-only change CI verified in 16 minutes. After writing the handoff
  the agent went back to retrying the lint and held the slot for nothing.
- **Deletion exposes a type error (2026-08-13, FXA-13034).** Removing a `canSend` flag across 26
  files made CI `Build` fail with `account.ts: TS7030`. An untyped fallback had widened the return
  type to `any` and hidden it. No unit test could catch that. Type-check every removal.

## Reconcile and CI

- **Stall declared from CPU (2026-08-11).** A run was nearly killed as "stalled" from process
  sampling while the launcher log already said `PR opened`. It took 58 minutes and succeeded.
  Read `progress` first.
- **Held paste (2026-08-31, FXA-10214).** The prompt was pasted into Claude's TUI and Enter never
  took. The agent sat 15 minutes while `progress`, `alive`, and `list` said fine. Since
  2026-09-14 the prompt is a `claude -p` argument, so nothing can be held.
- **`list` lies.** It reported `running` for six minutes after Claude Code exited and `exec bash`
  replaced it in the screen session. Empty `tail` was the hint. `alive` counts real processes.
- **Stale `from_failed`.** Rerunning a week-old workflow restores an expired cache and dies in
  "Run DB migrations" with `ERR_MODULE_NOT_FOUND: Cannot find package 'mysql'`. Zero test results
  is the signature. Use a full rerun.
- **Red after done (2026-08-25, #21073).** Red for six days while the ✅ list advertised it. The
  failing job was the l10n `extract` workflow: token lacked org team read scope, `HTTP 401` from
  `gh api /orgs/mozilla/teams/fxa-l10n/members`, then `jq: Cannot index string with string
  "login"`. Repo infrastructure, not the PR; the same job failed on `fxa-14373` the same day.
- **Reviewer question unanswerable (2026-08-25, #21101).** Whether a comment was addressed needed
  a diff of `localization.ts` against the comment text. Hence the 👍 on fixed comments.
- **Missing team review (2026-08-13, #21019).** CODEOWNERS usually requests `fxa-devs`; this PR
  opened without it. The launcher now requests it explicitly.

## Review feedback

- **Green is not correct (2026-08-14, #21038).** Copilot found `account.login` recorded as
  verified before TOTP completed, on two routes, while the ticket sat in `done`. The claim held
  under two checks: `patch-167-168.sql:36` stores `verified` as `inTokenVerificationId IS NULL`,
  and the helper's only `tokenId` source is `opts?.request?.auth?.credentials?.id`.
- **Line-counting JSON (2026-08-18).** An empty `feedback` result is four lines, so `wc -l`
  reported "4 unhandled comments" on all 14 done tickets, twice in one session. Count with `jq`.

## Conflicts

- **Invisible conflicts (2026-09-01).** Four of twelve `done` PRs were `CONFLICTING` while the ✅
  list advertised all twelve.
- **Churn (FXA-11871).** Mergeable at 14:02, conflicting by 16:00 after two unrelated merges.
- **First four measured:** one lockfile in five files; the rest `source`.

## Slots and state

- **Deadlocked pool (2026-08-24).** Two finished VMs idled four hours holding both slots; eight
  passes did nothing. `label` now reaps on every transition out of `inflight`.
- **Undrained done (2026-08-13).** 13 tickets in `done` while 9 needed review; 4 had merged and
  nothing moved them.
- **Duplicate PR (2026-09-08).** FXA-14300 had merged as #21139 while the automation was off.
  Draining it with `finish --create-pr` re-pushed the branch as duplicate #21167. FXA-14471 was
  one fire away from the same. Check `prstate` before any drain.
- **JQL lag (2026-08-13).** `inflight` still listed FXA-13919 right after it was labelled `done`;
  the field read showed the new label and the search caught up in about 8 seconds.
- **Disk (2026-08-11).** The host filled to 99% and needed a 19GB manual cleanup.

## Cost

- **Idle passes in a long session (2026-09-15).** Fourteen consecutive quiet passes each
  re-injected the 61KB skill into a session already at 400K+ tokens of context, adding 24K
  tokens per pass and about $4.60 of equivalent API spend for a one-line "changed nothing". The
  manager session cost 13 times the agents it launched. Hence `precheck` first, and this file
  split out of `SKILL.md`.

## Merged tickets were never closed

**2026-09-15.** `label KEY merged` wrote the label and the telemetry comment and stopped there, so
a merged ticket kept whatever status and assignee it had before the pipeline saw it. A count that
day found 34 merged or done ai-fixme tickets with no Jira assignee, 20 of them still at In Review
with the PR long since landed. The oldest was filed in 2020. Nothing in the pipeline re-reads a
merged ticket, so nothing would ever have noticed.

The fix hangs off the label write, for the same reason the VM reap and the 👍 do: a step that
depends on a pass remembering to run a separate command does not survive a cron-fired pass.

Three details cost a rewrite each:

- **The assignee is the approver, not the reporter.** The tool already resolved the reporter for
  the PR assignee, and reusing it here was the obvious move and the wrong one. The reporter filed
  the ticket; the reviewer who signed off is the one who owns it afterwards.
- **Last approval wins.** #21225 had two: an l10n reviewer approved the Fluent strings at 20:12 and
  the code owner approved at 22:19. The first approval is not the one that unblocked the merge.
- **Board 225 has two active sprints**, "FxA Sprint N" and "SubPlat Train N". Asking the board for
  its active sprint returns both, so a first-match pick would have filed FxA work into the SubPlat
  train. The lookup takes the sprint only when exactly one name matches.

`acli` cannot write the Sprint field: it rejects `customfield_*` in `--from-json` and has no flag
for it. That one step calls the Agile REST API directly and needs `PIPE_JIRA_BASIC`. Without the
token it warns and the rest of the close still runs, because an unsprinted ticket is a smaller
problem than a merge close that aborts halfway.

## The manager paid to re-read itself

**2026-09-17.** A cost split of the day's $102 manager spend: $53 was the session re-reading its
own 400K-token context, once per turn, and every tool call is a turn. Nine cron passes cost $36.
Four of those nine changed nothing but were not `quiet`, because a `watching` or `pr … running`
line counted as work and bought a lock, drain, sweep, unlock turn each.

Three passes read the same l10n `extract` failure log, the same `HTTP 401: Bad credentials`, on
three PRs. Two `done` tickets needed a model turn to type `label merged` for a MERGED drain line
the skill already calls determinate. Grounding five tickets took about twenty greps, each a full
context re-read.

Changes: precheck applies MERGED and CLOSED drain rows itself, approves a pending functional gate
at any age, classifies red checks against `PIPE_INFRA_CHECKS` and reports a match as `RED-INFRA`
(cached per head sha), sweeps feedback on `inflight` tickets with an open PR, holds back
informational lines, and prints one `quiet` line with counts. `ground KEY` and `feedback KEY
bundle` deliver the evidence for a judgment as one file instead of a tool call per fact.

On 2026-09-18 the operator ruled that a PR red only on a known infrastructure check is not a
failed PR. Reconcile now labels it `done` once nothing else runs, so review is not held for a
token nobody on the team can rotate. Three PRs had waited a day at `inflight` for that reason.

## Four parallel launches, one shared temp file

On 2026-09-18 a pass launched four tickets in one minute. Every GCE create appended its
per-host ssh entry with `cat - config > config.tmp && mv config.tmp config`, all four through
the same `.tmp` path. One launcher's `mv` landed while another's `cat` still had the file open,
so that `cat` read its own output for 25 minutes, wrote 82GB, took the disk from 73GB to 0GB,
and held its launcher at "Creating GCE instance" the whole time. In the same minute two other
launches pinned the runner before the image's checkout unit had created `/workspace`:
`vm_wait_ready` skips that wait when a single ssh flakes, and four IAP tunnels at once flake.
Both tickets went back to the queue with "runner is at ''".

Changes: per-host ssh entries are one file each under `logs/gce-ssh-hosts/`, pulled in by an
`Include` line, so nothing rewrites a shared file. `_gce_pin_runner_tree` polls for
`/workspace/.git` before it fetches, at the point of use, instead of trusting an earlier wait.

## The GCE runner had Playwright but no browsers

Agents reported that functional tests could not run in the VM. A bare runner on 2026-09-19
confirmed it: Playwright 1.61.1 was installed, `~agent/.cache/ms-playwright` did not exist, and
both `chromium.launch()` and `firefox.launch()` failed on a missing executable. Two causes. The
image's agent-init unit installs browsers only when `/workspace/packages/functional-tests`
exists, and on GCE `/workspace` is a symlink the checkout unit creates after agent-init, so the
step never ran. Then a manual install fetched Firefox but failed on Chromium's helper
downloads with `ENETUNREACH` to an IPv6 address: Node 24 tries AAAA answers first and the VM
has no IPv6 route.

Changes: the agent environment sets `NODE_OPTIONS=--dns-result-order=ipv4first`; the image
bakes Chromium and Firefox for the pinned Playwright at build time; the checkout unit runs
`playwright install` after it links `/workspace`, a no-op unless the branch moved the pin. The
functional tests use Firefox by default and Chromium for the `-chromium` and `-payments-next`
projects, so both are baked.

## The functional-test stack in a runner: five faults, one afternoon

With browsers present, a full `--project=local` run on a GCE runner failed 40 of 446 tests on
2026-09-19 while CI's nightly passed the same suite. The fastest diagnosis was, in order: check
CI (rules out the tests), open one saved Playwright trace (shows what the page received), and
list the hung process's sockets with `ss -tnp` (shows what a request waits on).

1. The nginx front proxy rewrote `/settings/static/X` to `/static/X` before forwarding to the
   settings dev server, which serves under `/settings/static/` and answers `/static/...` with
   its index page. Every React page loaded HTML as `bundle.js`; email-first never rendered.
2. The admin server was not started. The fixtures delete every test account through it, so
   each spec ended in `Failed to cleanup account` after a passing flow.
3. The admin server dies at boot on an empty Stripe key. A placeholder key lets it construct.
4. The auth server's `/cms/config` hung 75 s: a Google client probed the metadata server for
   default credentials, and the firewall drops the agent user's packets to it, so the connect
   sat in SYN-SENT. `METADATA_SERVER_DETECTION=none` in the agent env ends the probe at once.
5. An 8GB runner ran out of memory with the stack, an admin build and three Firefox workers
   up; the kernel killed the settings dev server mid-run. The admin panel dev server and the
   nest watch wrapper alone held 3.3GB. Only the admin server runs now, from its built dist,
   and `--functional-tests` launches on a 16GB machine type until an 8GB run is measured.

Also: every guide named a `sandbox` Playwright project that does not exist (`local` is the
one), and `pkill -f "playwright test"` over ssh kills the ssh shell that contains those words.
Two more, found the same day and left as documented limits on the operator's call: every
123done OAuth flow fails at `/v1/token` with errno 998 because the grant path calls the
subscriptions capability manager, which the runner cannot register without Stripe and Strapi;
and the `run` command never syncs secrets, so a relier needs `--functional-tests` through
`jira`. A full run is not the goal here; CI does that. A runner has to run the specs that cover one
issue, which the verification skill's flow now does in about ten seconds per spec.

Also found that day: review comments on a PR that never reached `done` were never swept, because
the sweep read `done` keys only. A red infrastructure check kept three Backbone-removal PRs at
`inflight` for hours with Copilot findings nobody saw.

## No PR ever carried a screenshot

Through 2026-09-19 every handoff file listed `media_paths: []`, so the host's
attach code had never run, and nothing in any log said so. Five faults stacked:

1. GCE runners had no Playwright browser until the 2026-09-19 image; the capture
   skill said "install nothing" and its shoot script threw at `firefox.launch()`.
2. The handoff skill's jq template hardcoded `media_paths:[]`. An agent that
   copied the template erased a successful capture. It now lists the media
   directory.
3. Storybook spawns `xdg-open` after the build; on a headless runner that is an
   uncaught ENOENT and the server dies seconds after its first 200. `--no-open`.
4. `waitUntil: 'networkidle'` timed out against the dev server. Wait for `load`,
   then for a child of `#storybook-root`.
5. Storybook 8 always renders `#error-message` hidden, so the skill's
   `count() > 0` guard refused every story. Test `isVisible()`.

Also: the pass has never launched with `--functional-tests`, so a flow video was
never possible. The context line `Launch with --functional-tests` now adds it.

`finish` prints `media: N listed, M attached` on every run, plus the agent's
reason from `.fxa-auto-media-skipped.txt`, so an empty list is visible. Verified
2026-09-20 on a throwaway runner: one ThirdPartyAuth story captured, listed,
pulled and turned into `--attach`.

## The pass never read the PR conversation

`feedback` read only inline review comments (`pulls/N/comments`, position not
null). A reviewer's "do not port this, remove it instead" on PR #21248 landed in
the conversation (`issues/N/comments`) on 2026-09-21 and was invisible to every
pass. Both endpoints are read now. Conversation ids carry an `i` prefix so
`thumbsup` hits the right reactions endpoint; bot comments and the pass's own 🤖
comments are dropped. A conversation comment has no diff line, so the bundle
shows it under "in the PR conversation" with no branch context.

## A round rewrote the PR body to describe only itself

FXA-13674 round 2 (2026-09-21) produced a body that said "these are the only two
files in the diff" for a six-file PR, because the goal asked for a description
of "the latest commit" and the host squashes every round into one. Copilot
flagged the contradiction. The goal now asks for the whole branch diff. The
same day's rounds were also recorded as kind `fix` because their context files
sat outside `/tmp/feedback/`; the skill now names that path.

## A functional run OOM-killed its own agent (2026-09-21)

FXA-9550 ran with `--functional-tests`, so the whole FxA stack was up on the
8GB runner. Goal step 2 said "unit tests for the changed packages", the agent
ran `nx test-unit fxa-auth-server`, and the kernel killed the node workers and
the agent at 20:09 and again at 20:16 (serial console: `Out of memory: Killed
process ... MainThread`). The VM stayed RUNNING but sshd stopped answering, so
`alive` said dead and the dashboard showed "agent exited, no output captured"
with 21 files touched. Rule: the goal now names the spec files beside the
changed files and forbids a whole package suite. The context file for a
functional run should name those specs. `FXA_GCE_MACHINE_TYPE_FUNCTIONAL`
(c4a-standard-4, 16GB) is the knob if a run must have the full suite.
