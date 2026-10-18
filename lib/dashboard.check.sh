#!/usr/bin/env bash
# Offline check of the dashboard's helpers: session titles, owners, conversation counts, Slack PR belts, the outcome card, Needs you counts, queue groups.
#   bash lib/dashboard.check.sh
set -u
command -v node >/dev/null || { echo "skip: needs node"; exit 0; }
page="$(dirname "$0")/../dashboard/index.html"
node -e '
eval(process.argv[1].replace(/^(let|const) /gm, "var "));  // a top-level let or const in eval would stay inside it
const cases = [
  ["Fix the login page\nmore detail", "Fix the login page"],
  ["The engineer tapped Open PR. Run git status and check.", "Open PR"],
  ["Copilot reviewed the PR. Its inline comments are below.", "Copilot review round"],
  ["CI failed on the PR: ci/circleci: Playwright (PR).\nFailing checks: x", "CI failed: ci/circleci: Playwright (PR)."],
  ["You asked:\n> which one?\nMy answer: File a Jira ticket\n\nEarlier messages in this Slack thread:\n> owner: x", "File a Jira ticket"],
  ["(From someone else in the thread, not the person who started this session.)\nbooo", "booo"],
  ["^\n\nEarlier messages in this Slack thread, for context:\n> owner: @bot @bot2 Look at the subscriptions code", "Look at the subscriptions code"],
  ["The host uses these drafts as they are.\n\nEarlier messages in this Slack thread:\n> owner: find the test gaps", "find the test gaps"],
  ["Messages in the thread that were not for you, for context only:\n> someone else: hi", "Reply in the thread"],
  ["", "(no request)"],
];
let fail = 0;
for (const [i, want] of cases) { const got = firstLine(i); if (got === want) console.log("ok   " + want); else { console.log(`FAIL want [${want}] got [${got}]`); fail = 1; } }
const now = new Date(), mid = new Date(now).setHours(0, 0, 0, 0) / 1000;
for (const [c, want] of [[mid + 60, "Today"], [mid - 60, "Yesterday"], [mid - 3 * 86400, "This week"], [mid - 9 * 86400, "Older"], [String(mid + 1), "Today"]]) {
  const got = sessDay(c); if (got === want) console.log("ok   day " + want); else { console.log(`FAIL day want [${want}] got [${got}]`); fail = 1; } }
globalThis.STATS = { rows: [{ src: "slack", key: "agent-a", usd: 10.19 }] };
for (const [name, ss, want] of [["a stopped session has the Stats row cost, not the transcript cost", { key: "agent-a", summary: JSON.stringify({ cost: 15.1 }) }, 10.19],
  ["a live session has its runner cost", { key: "agent-a", agent: { cost_so_far: 3 } }, 3], ["no Stats row: the summary cost", { key: "agent-b", summary: JSON.stringify({ cost: 2 }) }, 2]]) {
  const got = sessUsd(ss); if (got === want) console.log("ok   " + name); else { console.log(`FAIL ${name}: want [${want}] got [${got}]`); fail = 1; } }
globalThis.NO_USE = { n: 0, live: 0, usd: 0, last: 0 };
const nowIso = new Date().toISOString();
STATS.rows = [{ src: "slack", profile: "sync-storage", t0: Date.now() / 1000, usd: 1 }, { src: "pipeline", profile: "sync-storage", at: nowIso, usd: 2 },
  { src: "pass", profile: "sync-storage", at: nowIso, usd: 0.5 }, { src: "pipeline", profile: "fxa", at: "2020-01-01T00:00:00Z", usd: 9 }];
{ const u = teamUse()["sync-storage"], got = `${u.n}|${u.runs}|${u.usd}`, want = "1|1|3.5";
  if (got === want) console.log("ok   team use: cost from every source, sessions and runs counted apart"); else { console.log(`FAIL team use: want [${want}] got [${got}]`); fail = 1; } }
{ const day = n => new Date(Date.now() - n * 86400000).toISOString().slice(0, 10);
  const got = llmWeek([{ day: day(9), usd: 100 }, { day: day(8), usd: 50 }, { day: day(3), usd: 2 }, { day: day(0), usd: 1 }]);
  if (got === 3) console.log("ok   the LLM week counts 7 calendar days, not the last 7 rows"); else { console.log(`FAIL llm week: want [3] got [${got}]`); fail = 1; } }
{ const ss = [{ key: "c3", resume_from: "c2" }, { key: "c2", resume_from: "c1" }, { key: "c1" }, { key: "d1" }];
  const got = `${sessHeads(ss).map(x => x.key).join(",")}|${chainOf(ss[0], ss).map(x => x.key).join(",")}`;
  if (got === "c3,d1|c3,c2,c1") console.log("ok   one row per conversation: the newest session, and its chain"); else { console.log(`FAIL heads: want [c3,d1|c3,c2,c1] got [${got}]`); fail = 1; } }
const t = (name, got, want) => { if (got === want) console.log("ok   " + name); else { console.log(`FAIL ${name}: want [${want}] got [${got}]`); fail = 1; } };
STATS.rows = [{ src: "slack", profile: "fxa", key: "r2", conv: "r1", t0: Date.now() / 1000 }, { src: "slack", profile: "fxa", key: "r1", conv: "r1", t0: Date.now() / 1000 }];
t("team use: a resumed thread counts as one conversation", teamUse().fxa.n, 1);
globalThis.AGENTS = { sessions: [{ key: "s1", owner: "U1" }, { key: "s2", owner: "U1", owner_name: "Pat" }, { key: "s3", owner: "U2" }] };
t("owner: a session without a name borrows its Slack user\u2019s name", ownerName(AGENTS.sessions[0]), "Pat");
t("owner: no name anywhere falls back to the Slack id", ownerName(AGENTS.sessions[2]), "U2");
globalThis.SNAP = { queue: { ready: [], skipped: [{ key: "A-1", passes: 3 }, { key: "A-2", held_by: "A-9" }, { key: "A-3", in_queue: false }] } };
t("queue waits: skipped and still queued, not held, not gone", queueWaits().map(k => k.key).join(","), "A-1");
SNAP.open_prs = [{ number: 7, title: "fix(x): y", created: new Date(Date.now() - 4 * 86400000).toISOString(), branch: "agent-b1", key: null }];
AGENTS.sessions = [{ key: "agent-c2", resume_from: "agent-b1", owner_name: "Pat", state: "paused" }, { key: "agent-b1", branch: "agent-b1", state: "stopped" }];
{ const r = laneRows().find(x => x.t.pr === 7); t("a PR with no ticket gets a Slack belt with its session and owner", r && `${r.t.slack}|${r.t.sess.key}|${r.t.owner}|${r.kind}`, "true|agent-c2|Pat|warn"); }
globalThis.TEAMS = { teams: [{ profile: "monitor", read_only: true }] };
t("outcome: a read-only team\u2019s diff is posted in Slack", /diff posted in Slack/.test(outcomeHtml({ key: "m1", profile: "monitor", summary: JSON.stringify({ diff: "1 file changed" }) })), true);
AGENTS.sessions = [{ key: "agent-c2", resume_from: "agent-b1", pr_url: "https://github.com/mozilla/fxa/pull/9", state: "paused" }, { key: "agent-b1", state: "stopped", request: "First ask" }];
STATS.prs = [{ n: 9, state: "MERGED" }];
t("outcome: the PR from any session in the conversation, with its state", /#9[\s\S]*merged/.test(outcomeHtml(AGENTS.sessions[0])), true);
t("the conversation title is the first session\u2019s request", convTitle(AGENTS.sessions[0]), "First ask");
for (const [i, want] of [["Can you work on <https://mozilla-hub.atlassian.net/browse/FXA-14767>", "Can you work on FXA-14767"],
  ["review this <https://github.com/mozilla/fxa/pull/21480|the PR> :sweat_smile:", "review this the PR"],
  ["checkout this branch <https://github.com/mozilla/fxa/pull/21391", "checkout this branch mozilla/fxa#21391"],
  ["<@U0C4MF0C79U> look at <https://example.com/x/y>", "look at example.com"],
  ["review this https://github.com/mozilla/fxa/pull/21371 please", "review this mozilla/fxa#21371 please"],
  ["work on <https://mozilla-hub.atlassian.net/browse/STOR-460|mozilla-hub.atlassian.net/browse/STOR-460>", "work on STOR-460"], ["fix: keep a:b:c as it is", "fix: keep a:b:c as it is"]])
  t("title without Slack markup: " + want, firstLine(i), want);
t("a conversation\u2019s PR and its state, from any of its sessions", JSON.stringify(convPr(AGENTS.sessions[0])), JSON.stringify({ url: "https://github.com/mozilla/fxa/pull/9", n: 9, state: "MERGED" }));
t("no PR in the conversation", convPr({ key: "x" }), null);
globalThis.NEEDS = [{ chip: "Failing" }, { chip: "Conflicts" }, { chip: "Review" }, { chip: "Decide" }, { chip: "Decide", n: 21 }, { chip: "Blocked" }];
{ const c = needCounts(); t("needs you counts items: a \"N more\" row counts N", `${c.total}|${c.parts}`, "26|Fix 2 · Review 1 · Decide 22 · Blocked 1"); }
t("skips group by their reason, most passes first", JSON.stringify(skipGroups([{ key: "A", passes: 1, reason: "blocked: x" }, { key: "B", passes: 9, reason: "open design question" },
  { key: "C", passes: 5, reason: "Underspecified: y" }, { key: "D", passes: 3, reason: "Blocked: z" }]).map(([g, ks]) => g + ":" + ks.map(k => k.key).join(""))), JSON.stringify(["Needs a decision:B", "Underspecified:C", "Blocked:DA"]));
STATS.rows = [{ src: "slack", profile: "fxa", key: "s", t0: Date.now() / 1000, usd: 1 }, { src: "answer", profile: "fxa", at: nowIso, usd: 0.5 },
  { src: "pipeline", profile: "fxa", at: nowIso, usd: 2 }, { src: "pass", profile: "fxa", at: nowIso, usd: 0.25 }];
{ const u = teamUse().fxa; t("team cost: Slack and the pipeline apart", `${u.slack_usd}|${u.pipe_usd}|${u.usd}`, "1.5|2.25|3.75"); }
{ const lo = Date.parse("2026-10-02T00:00"), hi = Date.parse("2026-10-04T00:00");
  t("day rows inside the Stats range", inRange([{ day: "2026-10-01" }, { day: "2026-10-02" }, { day: "2026-10-03" }, { day: "2026-10-04" }], lo, hi).map(d => d.day).join(","), "2026-10-02,2026-10-03"); }
globalThis.TEAM_ADMIN = { admin: true, user: "admin@example.com" };
{ const now = 1700000000, row = (id, extra) => ({ id, version: 1, paused: 0, next: ["2026-10-21T09:00:00-04:00"], tick: now - 600, last: null, live: null,
    data: { name: `Review ${id}`, template: "code-review", prompt: "p", schedule: "weekdays 09:00", zone: "America/New_York", repos: ["mozilla/fxa"], channel: "C0123ABCD", mode: "report", max_usd: 10, skip_no_commits: true }, ...extra });
  const team = { profile: "fxa", repos: [{ slug: "mozilla/fxa", role: "work" }] };
  RT = { team: "fxa", list: [row(1)] };
  t("routines: a 10 min old tick says the scheduler is not running", /The scheduler last ran 10 min ago\. Routines are not running\./.test(routineListHtml(team, now)), true);
  RT.list = [row(1, { tick: now - 60 })];
  t("routines: a fresh tick shows no warning", /scheduler/.test(routineListHtml(team, now)), false);
  RT.list = [];
  t("routines: no routine is the empty state, with no warning", /No routines yet\. A routine runs a prompt on a schedule[\s\S]*/.test(routineListHtml(team, now)) && !/scheduler/.test(routineListHtml(team, now)), true);
  RT.list = [row(1), row(2, { live: { id: 9, state: "started", session: "agent-ab12" } })];
  RT.form = { id: 1, version: 1, d: { ...rtDraft(RT.list[0].data), name: "My unsaved name" }, dirty: true, errs: {} };
  const g = routinesGroup(team, now);
  t("routines: a repaint keeps the dirty draft while another row turns Running", /value="My unsaved name"/.test(g) && /Running<\/span> <a class="mono" href="#sessions\/live\/agent-ab12"/.test(g), true);
  t("routines: a live run turns Run now off", /data-rt-act="run" data-rt-id="2"[^>]*disabled/.test(g), true);
  t("routines: a weekly draft goes back to the same schedule", rtRoutine(rtDraft({ ...RT.list[0].data, schedule: "weekly fri 17:30" })).schedule, "weekly fri 17:30");
  TEAM_ADMIN = { admin: false };
  t("routines: a non-admin sees only that admins manage them", /Only a team admin can see and change routines\./.test(routinesGroup(team, now)) && !/Review 1/.test(routinesGroup(team, now)), true);
  TEAM_ADMIN = { admin: true }; RT.form = null; }
{ const team = { profile: "fxa", repos: [{ slug: "mozilla/fxa", role: "work" }] };
  const { errs, summary } = rtErrs("ERROR: channel: Channel C0123ABCD belongs to team monitor\nname: Use letters, digits, spaces and . _ ( ) - in the name, at most 40 characters");
  t("routines: the validator\u2019s lines become field errors and one summary", `${Object.keys(errs).join(",")}|${/^2 fields need a change: Channel C0123ABCD belongs to team monitor\./.test(summary)}`, "channel,name|true");
  RT = { team: "fxa", list: [], tpls: [], msg: summary, ok: false, form: { d: rtDraft(), errs, dirty: true } };
  const g = routinesGroup(team, 1700000000);
  t("routines: a refused save marks the bad field and points it at its reason", /id="rt-channel"[^>]*aria-invalid="true" aria-describedby="rt-channel-err"/.test(g) && /<p class="unknown" id="rt-channel-err">Channel C0123ABCD belongs to team monitor<\/p>/.test(g), true);
  t("routines: a good field is not marked", /id="rt-zone"[^>]*aria-invalid/.test(g), false);
  t("routines: the summary is one role=status line", /<p role="status" data-rt-msg class="unknown">2 fields need a change/.test(g), true);
  RT = { team: "fxa", list: [{ id: 3, version: 1, paused: 1, next: [], tick: 1700000000, data: { name: "UX review", schedule: "daily 09:00", zone: "UTC", channel: "C0123ABCD", mode: "report" } }] };
  const btns = routineListHtml(team, 1700000000).match(/<button [^>]*>/g) ?? [];
  t("routines: each row button has an aria-label that names the routine", btns.length >= 5 && btns.every(b => /aria-label="[^"]* UX review"/.test(b)), true); }
t("routines: History is stacked blocks at max-width 640px", /@media \(max-width:640px\) \{\s*table\.rt-hist thead \{ display: none; \}/.test(require("fs").readFileSync(process.argv[2], "utf8")), true);
{ globalThis.teamUsage = () => ""; globalThis.teamEditor = () => ""; globalThis.closeBtn = ""; globalThis.teamName = x => x.label || x.profile; globalThis.repoShip = () => ["ok", "", ""];
  globalThis.teamTools = () => "none"; globalThis.TEAMS = { teams: [] }; globalThis.TEAM_ADMIN = { admin: true };
  const team = { profile: "fxa", repos: [], issues: [] }, p = "echo $1 and $$HOME $& $` $\u0027 done";
  RT = { team: "fxa", list: [], tpls: [], form: { d: { ...rtDraft(), prompt: p }, errs: {}, dirty: true } };
  for (const tab of ["routines", "all"]) { TAB = tab; const h = teamDetails(team);
    t(`routines (${tab} tab): a prompt with $ patterns renders unchanged`, h.includes(`>${esc(p)}</textarea>`), true); }
  TAB = "routines"; const h = teamDetails(team);
  t("routines: the Routines tab puts the group first in the panel", h.indexOf("data-routines") < h.indexOf("<h4>Access"), true); }
process.exit(fail);
' "$(sed -n '/^const esc = /p; /^const days = /p; /^const plainMd = /p; /^const queueWaits = /p; /^function ownerName(s) {/,/^}/p; /^const sessTabOf = /p; /^const sessLink = /p; /^const convTitle = /p; /^const sessSummary = /p; /^function outcomeHtml(s) {/,/^}/p; /^function merged() {/,/^}/p; /^function laneRows() {/,/^}/p; /^function firstLine(t) {/,/^}/p; /^function sessDay(c) {/,/^}/p; /^let STAT_USD/p; /^function sessUsd(s) {/,/^}/p; /^function slackText(t) {/,/^}/p; /^const ageOf = /p; /^function convPr(s) {/,/^}/p; /^const NEED_KIND = /p; /^function needCounts() {/,/^}/p; /^function skipGroups(ks) {/,/^}/p; /^const inRange = /p; /^function teamUse() {/,/^}/p; /^function llmWeek(days) {/,/^}/p; /^function sessHeads(ss) {/,/^}/p; /^function chainOf(s, ss) {/,/^}/p; /^const kvr = /p; /^const stamp = /p; /^const usd = /p; /^let RT = /p; /^const RT_/p; /^function rtDraft(/,/^}/p; /^function rtRoutine(/,/^}/p; /^function rtErrs(/,/^}/p; /^const rtWhen = /p; /^const rtSched = /p; /^function rtState(/,/^}/p; /^function rtLast(/,/^}/p; /^function rtHist(/,/^}/p; /^function rtRow(/,/^}/p; /^function routineListHtml(/,/^}/p; /^function routineForm(/,/^}/p; /^function routinesGroup(/,/^}/p; /^function teamDetails(t) {/,/^}/p; /^const kvr = /p; /^let TAB/p' "$page")" "$page"
