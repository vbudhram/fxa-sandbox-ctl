#!/usr/bin/env bash
# Offline check of the dashboard's helpers: session titles, owners, conversation counts, Slack PR belts, the outcome card, Needs you counts, queue groups.
#   bash lib/dashboard.check.sh
set -u
command -v node >/dev/null || { echo "skip: needs node"; exit 0; }
page="$(dirname "$0")/../dashboard/index.html"
# The JS reads from a quoted heredoc, so an apostrophe in it is safe.
fns="$(sed -n '/^const esc = /p; /^const days = /p; /^const plainMd = /p; /^const queueWaits = /p; /^function ownerName(s) {/,/^}/p; /^const sessTabOf = /p; /^const sessRoutine = /p; /^const sessRoutineLink = /p; /^const teamName = /p; /^const teamLabel = /p; /^const sessLink = /p; /^const convTitle = /p; /^const sessSummary = /p; /^function outcomeHtml(s) {/,/^}/p; /^function merged() {/,/^}/p; /^function laneRows() {/,/^}/p; /^function firstLine(t) {/,/^}/p; /^function sessDay(c) {/,/^}/p; /^let STAT_USD/p; /^function sessUsd(s) {/,/^}/p; /^function slackText(t) {/,/^}/p; /^const ageOf = /p; /^function convPr(s) {/,/^}/p; /^const NEED_KIND = /p; /^function needCounts() {/,/^}/p; /^function skipGroups(ks) {/,/^}/p; /^const inRange = /p; /^function teamUse() {/,/^}/p; /^function llmWeek(days) {/,/^}/p; /^function sessHeads(ss) {/,/^}/p; /^function chainOf(s, ss) {/,/^}/p; /^const kvr = /p; /^const stamp = /p; /^const usd = /p; /^let RT = /p; /^const RT_/p; /^function rtDraft(/,/^}/p; /^function rtRoutine(/,/^}/p; /^function rtErrs(/,/^}/p; /^const rtWhen = /p; /^const rtSched = /p; /^function rtState(/,/^}/p; /^function rtLast(/,/^}/p; /^function rtHist(/,/^}/p; /^function rtRow(/,/^}/p; /^function routineListHtml(/,/^}/p; /^function routineForm(/,/^}/p; /^function routinesGroup(/,/^}/p; /^function teamDetails(t) {/,/^}/p; /^const kvr = /p; /^let TAB/p; /^async function loadRoutines(/,/^}/p; /^async function rtDo(/,/^}/p; /^function rtKeepForm(/,/^}/p; /^function rtFocus(/,/^}/p; /^const rtSay = /p; /^const rtPr = /p; /^const prHref = /p; /^const sessHref = /p; /^const VIEWS = \[/,/^\];/p' "$page"; sed -n '/^const agentsMore = /p; /^const KEY_RE = /p; /^const TEAM_RE = /p; /^const LIVE_SESSION = /p; /^let TTAB = /p; /^const TTABS = /p; /^function teamRoute(/,/^}/p; /^function rtSelected(/,/^}/p; /^const rtFailed = /p; /^async function rtLoadHist(/,/^}/p; /^const rtSum = /p; /^const spendSkip = /p; /^const teamNeeds = /p; /^function teamReason(/,/^}/p; /^function teamItem(/,/^}/p; /^function teamErrs(/,/^}/p; /^function teamWeek(/,/^}/p; /^function budgetCell(t) {/,/^}/p; /^function testCell(t) {/,/^}/p; /^function allTeamsHtml(/,/^}/p; /^function teamSettingsHtml(/,/^}/p; /^function teamPageHtml(/,/^}/p; /^let ACCESS_DRAFT = /p; /^const accessList = /p; /^function teamAccessCard(/,/^}/p; /^async function accessSave(/,/^}/p; /^function teamBanner(/,/^}/p; /^function teamRecent(/,/^}/p; /^function teamActivity(/,/^}/p; /^function teamReadiness(/,/^}/p; /^function teamOverview(/,/^}/p; /^const teamLevel = /p; /^const teamBadge = /p; /^const teamAccess = /,/;$/p; /^const NEXT_STEP = {/,/^};/p; /^const KIND_LABEL = {/,/fault: "fault" }/p; /^const skipKindOf = /p; /^const boardAge = /p; /^const secsSince = /p; /^function classify(i) {/,/^}/p; /^function boardItems() {/,/^}/p; /^function gateLine(/,/^}/p; /^const needMeta = /p; /^const boardAct = /p; /^function boardState(col) {/,/^}/p; /^function boardRow(i) {/,/^}/p; /^function boardHtml() {/,/^}/p; /^function boardDetails(i) {/,/^}/p; /^function tabCount(t) {/,/^}/p; /^const REPO_RE = /p; /^function safeRender(/,/^}/p; /^function teamRepo() /p; /^function jiraHref(/p; /^function prUrl(/p; /^const ago = /,/^const short = /p; /^const LANE_ST = /p; /^const LANE_OUT = /p; /^function laneTitle(/,/^}/p; /^function openPrCounts(/,/^}/p; /^function openPrLine(/,/^}/p; /^let OUTSIDE_OPEN/p; /^const BELT_GROUPS = /,/\]\];$/p; /^function beltGroups(/,/^}/p; /^const beltCount = /p; /^function beltRow(/,/^}/p; /^function beltsHtml(/,/^}/p' "$page")"
node - "$fns" "$page" <<'JS'
process.argv.splice(1, 1);  // node - puts "-" at argv[1]
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
globalThis.SNAP = { team: { repo: "mozilla/fxa" }, queue: { ready: [], skipped: [{ key: "A-1", passes: 3 }, { key: "A-2", held_by: "A-9" }, { key: "A-3", in_queue: false }] } };
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
  RT.list = [row(1, { tick: now - 60 }), row(2, { tick: now - 600 })];
  t("routines: a fresh tick of one env does not hide a stale one", /last ran 10 min ago/.test(routineListHtml(team, now)), true);
  RT.list = [row(1, { tick: now - 60 })];
  t("routines: a fresh tick shows no warning", /scheduler/.test(routineListHtml(team, now)), false);
  RT.list = [];
  t("routines: no routine is the empty state, with no warning", /No routines yet\. A routine runs a prompt on a schedule[\s\S]*/.test(routineListHtml(team, now)) && !/scheduler/.test(routineListHtml(team, now)), true);
  RT.list = [row(1), row(2, { live: { id: 9, state: "started", session: "agent-ab12" } })];
  RT.form = { id: 1, version: 1, d: { ...rtDraft(RT.list[0].data), name: "My unsaved name" }, dirty: true, errs: {} };
  const g = routinesGroup(team, now);
  t("routines: a repaint keeps the dirty draft while another row turns Running", /value="My unsaved name"/.test(g) && /Running<\/span> <a class="mono" href="#sessions\/live\/agent-ab12"/.test(g), true);
  RT.sel = 2; t("routines: a live run turns Run now off", /data-rt-act="run" data-rt-id="2"[^>]*disabled/.test(routinesGroup(team, now)), true); RT.sel = undefined;
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
  t("routines: the summary is one role=status line", /<p role="status" data-rt-msg tabindex="-1" class="unknown">2 fields need a change/.test(g), true);
  RT = { team: "fxa", list: [{ id: 3, version: 1, paused: 1, next: [], tick: 1700000000, data: { name: "UX review", schedule: "daily 09:00", zone: "UTC", channel: "C0123ABCD", mode: "report" } }] };
  const btns = rtRow(RT.list[0]).match(/<button [^>]*>/g) ?? [];
  t("routines: each row button has an aria-label that names the routine", btns.length >= 5 && btns.every(b => /aria-label="[^"]* UX review"/.test(b)), true); }
t("routines: History is stacked blocks at max-width 640px", /@media \(max-width:640px\) \{\s*table\.rt-hist thead \{ display: none; \}/.test(require("fs").readFileSync(process.argv[2], "utf8")), true);
{ globalThis.teamUsage = () => ""; globalThis.teamEditor = () => ""; globalThis.closeBtn = ""; globalThis.teamName = x => x.label || x.profile; globalThis.repoShip = () => ["ok", "", ""];
  globalThis.teamTools = () => "none"; globalThis.TEAMS = { teams: [{ profile: "fxa", repos: [], issues: [] }] }; globalThis.TEAM_ADMIN = { admin: true };
  const p = "echo $1 and $$HOME $& $` $\u0027 done";
  RT = { team: "fxa", list: [], tpls: [], form: { d: { ...rtDraft(), prompt: p }, errs: {}, dirty: true } };
  TTAB = "routines"; const h = teamPageHtml("fxa");
  t("routines (Routines tab): a prompt with $ patterns renders unchanged", h.includes(`>${esc(p)}</textarea>`), true);
  t("routines: the Routines tab holds the routines group", h.includes("data-routines"), true);
  globalThis.TEAM_ADMIN = { admin: false }; t("routines: a viewer who is not an admin sees no routines", /Only a team admin can see and change routines/.test(teamPageHtml("fxa")) && !teamPageHtml("fxa").includes("data-routines"), true);
  globalThis.TEAM_ADMIN = { admin: true }; TTAB = "overview"; RT = { team: null }; }
// The Teams page (epic i275 slice 4): URLs, the side list, the badge, All teams and the team heading.
t("teams route: the new forms", JSON.stringify([teamRoute(undefined), teamRoute("fxa"), teamRoute("fxa", "routines"), teamRoute("fxa", "settings"), teamRoute("new")].map(r => `${r.sel}/${r.tab}`)),
  JSON.stringify(["__all/overview", "fxa/overview", "fxa/routines", "fxa/settings", "__new/overview"]));
t("teams route: old links are replaced", `${teamRoute("routines", "fxa").replace}|${teamRoute("all").replace}|${teamRoute("routines", "../x").replace}`, "#teams/fxa/routines|#teams|#teams");
t("teams route: an odd name is kept raw, never decoded", teamRoute("%E0").sel, "%E0");
{ globalThis.TEAMS = { teams: [{ profile: "fxa", label: "FxA", repos: [], issues: [], access: { open: "built-in" } }, { profile: "ent", label: "Entitlements", repos: [], issues: [{ level: "warn", text: "nobody can start it" }], access: { record: true, status: "disabled" } },
    { profile: "crew", label: "Crew <img src=x>", repos: [], issues: [], access: { open: true } }] };
  RTSUM = { teams: { crew: { routines: 3, failed: 1, paused: 0 }, ent: { routines: 4, failed: 0, paused: 1 } } };
  globalThis.TEAM_ADMIN = { admin: true };
  t("teams: a failed routine puts a team in Needs attention for an admin", `${teamNeeds(TEAMS.teams[2])}|${teamReason(TEAMS.teams[2])}`, "true|3 routines · 1 failed");
  t("teams: a team that is not active leads with its status", teamReason(TEAMS.teams[1]), "disabled · 4 routines");
  t("teams: the badge is warn for a failed routine", teamBadge([TEAMS.teams[0], TEAMS.teams[2]]), " warn");
  globalThis.TEAM_ADMIN = { admin: false };
  t("teams: a viewer who is not an admin gets no routine facts", `${teamNeeds(TEAMS.teams[2])}|${teamReason(TEAMS.teams[1])}|${teamBadge([TEAMS.teams[2]])}`, "false|disabled|");
  globalThis.TEAM_ADMIN = { admin: true };
  globalThis.ERRS = null; globalThis.STATS = null; const all = allTeamsHtml();
  t("all teams: four tiles and one row per team, names escaped", `${(all.match(/class="ttile[ "]/g) || []).length}|${(all.match(/<tr><td>/g) || []).length}|${/<img src=x>/.test(all)}`, "4|3|false");
  t("all teams: an unknown feed shows a dash, never a zero", /Active now<\/div><div class="tv">— /.test(all), true);
  TTAB = "overview"; const pg = teamPageHtml("ent");
  t("team page: a heading to focus, the source, and three tab links", `${/<h2 class="th" id="team-h" tabindex="-1">Entitlements/.test(pg)}|${(pg.match(/class="ttab"/g) || []).length}|${/href="#teams\/ent\/routines"/.test(pg)}`, "true|3|true");
  t("team page: the current tab has aria-current", /href="#teams\/ent" aria-current="page">Overview/.test(pg), true);
  t("team page: an unknown team says so, escaped", /No team &lt;b&gt;/.test(teamPageHtml("<b>")), true);
  // The Overview tab (slice 5): one banner by viewer, the cost card, last test, open errors, no routine name for a non-admin, Readiness.
  { const ent = { profile: "ent", label: "Ent", repos: [{ slug: "a/b", role: "work" }], issues: [{ level: "warn", text: "nobody can start it" }], access: { record: true, status: "active", users: 0 } };
    RTSUM = { teams: { ent: { routines: 2, failed: 1, paused: 0, live: 0, runs_30d: 3, cost_30d: 1.5, last_failed: { name: "Nightly", at: 1, reason: "the turn stopped" } } } };
    globalThis.TEAM_ADMIN = { admin: true };
    t("overview: an admin gets the first problem, its action, and the rest as a count", `${/Nobody can start this team/.test(teamBanner(ent))}|${/>Add users</.test(teamBanner(ent))}|${/and 1 more/.test(teamBanner(ent))}`, "true|true|true");
    globalThis.TEAM_ADMIN = { admin: false };
    t("overview: a viewer who is not an admin gets the text, no button, and no routine count", `${/A team admin can fix this/.test(teamBanner(ent))}|${/<a /.test(teamBanner(ent))}|${/and 1 more/.test(teamBanner(ent))}`, "true|false|false");
    globalThis.TEAM_ADMIN = { admin: true };
    globalThis.STATS = { rows: [] }; globalThis.ERRS = [{ status: "open", keys: ["agent-e1", "agent-e2"] }, { status: "open", keys: ["agent-e3"] }, { status: "resolved", keys: ["agent-e1"] }];
    globalThis.AGENTS = { sessions: [{ key: "agent-e1", profile: "fxa" }, { key: "agent-e3", profile: "fxa" }, { key: "agent-r1", profile: "fxa", routine_run: 7, routine_name: "Code review" }] };
    t("overview: open errors per team through their sessions", teamErrs().fxa, 2);
    const fx = { profile: "fxa", label: "FxA", repos: [{ slug: "mozilla/fxa", role: "work" }], issues: [], access: { open: "built-in" }, budget: { month_usd: 1041.09, month_cap: 1500 } };
    t("overview: the cost card shows this month against the cap", /\$1,?041\.09.*of \$1,?500/.test(teamOverview(fx).replace(/\s+/g, " ")), true);
    t("overview: unreadable spend says so, never $0", /budget unknown: the spend file cannot be read/.test(teamOverview({ ...fx, budget: null, budget_error: "unreadable" })), true);
    t("overview: a healthy team has a one-line Readiness", /5 of 5 good/.test(teamReadiness(fx)), true);
    t("overview: access that cannot be read is unknown, not good", /<b>Access<\/b>[^]*?class="tag ">unknown/.test(teamReadiness({ ...fx, profile: "crew", access: null })), true);
    STATS.rows = [{ key: "agent-r1", src: "slack", profile: "fxa", t0: Date.now() / 1000 - 60 }];
    t("overview: a routine run is named for an admin", /Routine: Code review/.test(teamRecent("fxa")), true);
    globalThis.TEAM_ADMIN = { admin: false };
    t("overview: a viewer who is not an admin sees no routine name", /Code review/.test(teamRecent("fxa")), false);
    globalThis.TEAM_ADMIN = { admin: true }; globalThis.STATS = null; globalThis.ERRS = null; }
  // The Routines tab (slice 6): the Show filter, the On switch, and the routine that ran last.
  { globalThis.TEAM_ADMIN = { admin: true };
    const mk = (id, name, extra) => ({ id, version: 1, paused: 0, data: { name, template: "code-review", schedule: "daily 09:00", zone: "UTC", mode: "report", channel: "" }, next: [], last: null, ...extra });
    RT = { team: "fxa", list: [mk(1, "Alpha", { last: { state: "ok", ended_at: 100 } }), mk(2, "Beta", { last: { state: "failed", ended_at: 300 } }), mk(3, "Gamma", { paused: 1, last: { state: "ok", ended_at: 200 } })] };
    RTSUM = { teams: {}, routines: { 1: { last_end: 100, failed: false, cost_30d: 1 }, 2: { last_end: 300, failed: true, cost_30d: 2 }, 3: { last_end: 200, failed: false, cost_30d: 0 } } };
    const rows = show => { RT.show = show; return (routineListHtml({ profile: "fxa" }, Date.now() / 1000).match(/data-rt-sel="\d+">[A-Za-z]+/g) || []).map(x => x.replace(/.*>/, "")).join(","); };
    t("routines tab: Show all, failed and paused", `${rows("all")}|${rows("failed")}|${rows("paused")}`, "Alpha,Beta,Gamma|Beta|Gamma");
    RT.show = "all"; const h = routineListHtml({ profile: "fxa" }, Date.now() / 1000);
    t("routines tab: the On switch posts pause or resume, with aria-pressed and a label", `${/data-rt-act="pause" data-rt-id="1" aria-pressed="true" aria-label="Routine Alpha on"/.test(h)}|${/data-rt-act="resume" data-rt-id="3" aria-pressed="false"/.test(h)}`, "true|true");
    t("routines tab: it opens on the routine that ran last", rtSelected(RT.list).data.name, "Beta");
    RT.sel = 3; t("routines tab: a picked routine stays picked", rtSelected(RT.list).data.name, "Gamma"); RT.sel = undefined;
    RT.histErr = { 2: "HTTP 500" }; t("routines tab: runs that did not load say so, with Retry", /Runs did not load: HTTP 500 <button data-rt-act="hist" data-rt-id="2">Retry/.test(routineListHtml({ profile: "fxa" }, Date.now() / 1000)), true);
    RT = { team: null }; }
  // Settings and Access (slice 7)
  { globalThis.TEAM_ADMIN = { admin: true };
    const fx = { profile: "fxa", repos: [], issues: [], access: { open: "built-in" } }, env = { profile: "pyfxa", repos: [], issues: [], access: { open: false, users: 2, channels: 0, jira: [] } };
    t("access: FxA and an env team render no input and no Save access", `${/<input|Save access/.test(teamAccessCard(fx))}|${/<input|Save access/.test(teamAccessCard(env))}|${/Set in the bot \.env by the operator/.test(teamAccessCard(env))}`, "false|false|true");
    const rt = { profile: "rusty", repos: [], issues: [], access: { record: true, status: "active", open: false, users: 1, channels: 0, jira: [] } };
    globalThis.TED = { name: "rusty", gen: "7", ok: true, rec: { name: "rusty", access: { users: ["U0AAA1111"], channels: [] } }, text: "{}" }; ACCESS_DRAFT = null;
    t("access: the form fills from the record", /id="t-users" data-acc="users" value="U0AAA1111"/.test(teamAccessCard(rt)), true);
    globalThis.TEAM_ADMIN = { admin: false }; t("access: a viewer who is not an admin gets the text, no form", `${/A team admin adds users/.test(teamAccessCard(rt))}|${/<input/.test(teamAccessCard(rt))}`, "true|false"); globalThis.TEAM_ADMIN = { admin: true };
    globalThis.TED = { name: "rusty", ok: false, msg: "HTTP 500" }; t("access: a record that did not load says so, with no empty form", `${/The record did not load: HTTP 500/.test(teamAccessCard(rt))}|${/id="t-users"/.test(teamAccessCard(rt))}`, "true|false");
    t("access: a list keeps each ID once", accessList("U1, U2  U1,,U3").join(" "), "U1 U2 U3"); }
  { globalThis.TEAM_ADMIN = { admin: true }; RTSUM = { teams: { solo: { routines: 1, failed: 0 } } };
    const solo = { profile: "solo", repos: [], issues: [{ level: "info", text: "spend cannot be read" }], access: { open: true } };
    t("teams: unreadable spend with routines needs attention, with the reason and a warn badge", `${teamNeeds(solo)}|${teamReason(solo)}|${teamBadge([solo])}`, "true|routines are skipped: the team\u0027s spend cannot be read · 1 routine| warn");
    RTSUM = null; t("teams: without routines it stays under Teams", `${teamNeeds(solo)}|${teamBadge([solo])}`, "false|"); }
  t("last test: a pass at the current generation with no log", testCell({ access: { record: true, status: "active" }, test: { result: null, tested: 14, generation: 14 } }), "\u003cspan class=\"tag ok\">passed at generation 14\u003c/span>");
  t("last test: a pass at an older generation", /last passed at generation 12/.test(testCell({ access: { record: true, status: "active" }, test: { result: null, tested: 12, generation: 13 } })), true);
  t("last test: a draft with no pass", /not tested at this generation/.test(testCell({ access: { record: true, status: "draft" }, test: { result: null, tested: null, generation: 2 } })), true);
  t("last test: never says never run", /never run/.test([12, null].map(x => testCell({ access: { record: true, status: "active" }, test: { result: null, tested: x, generation: 13 } })).join("")), false);
  globalThis.TEAMS = { teams: [] }; RTSUM = null; }
// A hung await would end node with code 0 and no FAIL line: the guard keeps the loop alive and fails.
{ // Links come from the team block and fail closed.
  const snap = SNAP;
  globalThis.SNAP = { team: { jira_site: "https://jira.example.com", repo: "example/app", pr_label: "bot-pr", queue_label: "ai-queue" } };
  t("links: a Jira key and a PR number from the team block", `${jiraHref("ABC-12")}|${prUrl(7)}`, "https://jira.example.com/browse/ABC-12|https://github.com/example/app/pull/7");
  const sites = ["javascript:alert(1)", "https://jira.example.com/x", "http://jira.example.com", ""].map(j => { globalThis.SNAP = { team: { jira_site: j } }; return jiraHref("ABC-1"); });
  const repos = ["../x", "../..", "a/b/c", "a/..", ""].map(r => { globalThis.SNAP = { team: { repo: r } }; return prUrl(1); });
  t("links: a bad Jira site or repo gives no href", sites.join("") + repos.join(""), "");
  globalThis.SNAP = {}; t("links: no team block gives no Jira href; a bad key gives none", `${jiraHref("ABC-1")}|${(globalThis.SNAP = { team: { jira_site: "https://jira.example.com" } }, jiraHref("x\u0022><img"))}`, "|");
  t("links: rtPr refuses dot paths and keeps a real PR", `${rtPr("https://github.com/../../pull/1")}|${rtPr("https://github.com/example/repo/pull/1")}`, "|https://github.com/example/repo/pull/1");
  t("links: a pipeline key in a link is a Jira key or a branch", ["FXA-1", "agent-22d438", "<img src=x>", "../x", ""].map(k => BELT_KEY_RE.test(k)).join(","), "true,true,false,false,false");
  globalThis.SNAP = { team: { repo: "example/app" }, open_prs: [{ number: 5, key: null, branch: "agent-abc123", title: "t", created: new Date().toISOString() }], review: [], inflight: [] };
  const sess = { key: "agent-abc123", branch: "agent-abc123", routine_run: 1, routine: "nightly", team: "t1", user: "U1", created: 1 };
  const owner = a => { globalThis.TEAM_ADMIN = { admin: a }; globalThis.AGENTS = { sessions: [sess] }; return laneRows().map(r => r.l2).join(""); };
  t("routines: a non-admin sees a scheduled run, never the routine name", /nightly/.test(owner(false)), false);
  globalThis.SNAP = { repo: "example/app", review: [{ key: "FXA-3", pr: 3, title: "t", created: "2026-01-01T00:00:00Z" }] };
  t("an old snapshot with no team block: lanes still build", laneRows().length, 1);
  globalThis.SNAP = snap; }
{ // A section that throws shows its error in place, and the next renderer still runs.
  const out = {}, put0 = globalThis.put, ce = console.error; globalThis.put = (id, h) => { out[id] = h; }; console.error = () => {};
  safeRender(() => { throw new Error("boom <b>"); }, "s-lanes"); let next = false; safeRender(() => { next = true; }, "s-needs");
  t("render: a throwing section says so, escaped, and the next one runs", `${/did not render: boom &lt;b&gt;\. Reload, or run vm.sh rollback/.test(out["s-lanes"])}|${next}`, "true|true");
  globalThis.put = put0; console.error = ce; }
{ // Belts v2 on the pipeline fixture: four groups in order, each key once, counts that agree.
  const fx = JSON.parse(require("fs").readFileSync(require("path").join(require("path").dirname(process.argv[2]), "../skills/fxa-ctl-dev/page-fixture-pipeline.json"), "utf8"))["/api/snapshot"];
  const s0 = [globalThis.SNAP, globalThis.AGENTS, globalThis.STATE, globalThis.TEAM_ADMIN];
  const load = () => { globalThis.SNAP = JSON.parse(JSON.stringify(fx.snapshot)); globalThis.AGENTS = JSON.parse(JSON.stringify(fx.agents)); globalThis.STATE = { agents_age_seconds: 20, agents_interval: 30 }; globalThis.TEAM_ADMIN = { admin: false }; globalThis.SEL = {}; };
  load(); const g = beltGroups(), keys = k => g[k].map(r => r.t.key).join(",");
  t("belts: groups and keys", ["working", "needs", "fixes", "review", "outside"].map(keys).join(" | "), "FXA-20,FXA-21 | FXA-1,FXA-6 | FXA-4,FXA-3 | FXA-10,FXA-11,FXA-22 | agent-abc123,FXA-41");
  const all = ["working", "needs", "fixes", "review", "outside"].flatMap(k => g[k].map(r => r.t.key));
  t("belts: each key once; a hold, a ready ticket and a merged PR have no belt", `${new Set(all).size === all.length}|${["FXA-7", "FXA-30", "FXA-12"].some(k => all.includes(k))}`, "true|false");
  t("belts: Needs you equals boardAct, and the belt count is the four groups", `${g.needs.length === boardAct(boardItems())}|${beltCount(g)}`, "true|9");
  t("belts: the CI running PR waits on review, and the outside rows name their source", `${g.review.find(r => r.t.key === "FXA-22").l1}|${g.outside.map(r => r.l1).join(";")}`, "CI running|Slack · Sample Person's session;Not in the pipeline");
  const h = beltsHtml(g), order = [...h.matchAll(/<h2[^>]*>.*?<\/i>([^<]+) <span class="cnt">(\d+|\?)/g)].map(m => m[1] + " " + m[2]).join(", ");
  t("belts: the headings in order with counts", order, "Working now 2, Needs you 2, The agent fixes it 2, Waits on review 3");
  t("belts: the header line", /2 agents work now<\/span>\s*<span>· 9 belts<\/span><span>· 2 need you/.test(h), true);
  const row = k => beltRow(["working", "needs", "fixes", "review"].flatMap(x => g[x]).find(r => r.t.key === k));
  const f3 = row("FXA-3"), f20 = row("FXA-20");
  t("belts: track nodes, stop text and no callout", `${(f3.match(/class="n done"/g) || []).length}|${(f3.match(/class="n cur"/g) || []).length}|${(f3.match(/class="n"/g) || []).length}|${/aria-hidden="true">/.test(f3)}|${/Stop 7 of 9, CI</.test(f3)}|${/class="mark"/.test(h)}`, "6|1|2|true|true|false");
  t("belts: a live agent pulses and says so", `${/class="n cur live"/.test(f20)}|${/Stop 3 of 9, Agent, agent working/.test(f20)}|${/Agent · 12 min/.test(f20)}|${/yarn test example-server/.test(f20)}|${/id="lane-term-FXA-20"/.test(f20)}`, "true|true|true|true|true");
  load(); SNAP.blocked[0].summary = "<img src=x onerror=alert(1)>"; AGENTS.runners[0].agent.last_tool = "<img src=x>"; const hx = beltsHtml(beltGroups());
  t("belts: text from feeds is escaped", `${/&lt;img/.test(hx)}|${/<img src=x/.test(hx)}`, "true|false");
  load(); SNAP.inflight = []; SNAP.review = []; SNAP.blocked = []; SNAP.queue.skipped = []; SNAP.queue.ready = []; SNAP.open_prs = []; AGENTS.runners = []; AGENTS.sessions = [];
  const ge = beltGroups(), he = beltsHtml(ge);
  t("belts: empty groups say so, with no Outside group", `${["No agent works now.", "Nobody needs to act.", "Nothing for the agent to fix.", "No PR waits on review."].every(x => he.includes(x))}|${/bout/.test(he)}|${beltCount(ge)}`, "true|false|0");
  const unk = [() => { globalThis.SNAP = null; }, () => { SNAP.queue.fetch_failed = true; SNAP.blocked = null; }, () => { SNAP.review = null; SNAP.open_prs = null; }, () => { SNAP.review = null; },
    () => { STATE.agents_error = "x"; }, () => { STATE.agents_age_seconds = 900; STATE.agents_interval = 60; }].map(f => { load(); f(); const gg = beltGroups(), hh = beltsHtml(gg); return [hh, beltCount(gg)]; });
  t("belts: before a snapshot, loading with no counts", `${/Loading the pipeline/.test(unk[0][0])}|${/\d belts/.test(unk[0][0])}`, "true|false");
  t("belts: an unknown feed shows ? and its reason, never 0", [
    /unknown, Jira fetch failed/.test(unk[1][0]) && /\? need you/.test(unk[1][0]),
    (unk[2][0].match(/unknown, GitHub fetch failed/g) || []).length === 2,
    (unk[3][0].match(/unknown, Jira fetch failed/g) || []).length === 2,
    /unknown, agents feed fetch failed/.test(unk[4][0]) && /\? agents work now/.test(unk[4][0]),
    /unknown, agents feed 15 min old/.test(unk[5][0]),
    unk.slice(1).every(([hh, n]) => n === null && /\? belts/.test(hh))].join(","), "true,true,true,true,true,true");
  [globalThis.SNAP, globalThis.AGENTS, globalThis.STATE, globalThis.TEAM_ADMIN] = s0; }
setTimeout(() => { console.log("FAIL the async checks did not finish"); process.exit(1); }, 10000);
(async () => {
  globalThis.fetch = async url => ({ ok: true, json: async () => url.includes("templates") ? [{ template: "x" }] : [{ id: 7, data: {} }] });
  { const calls = []; globalThis.renderTeams = () => {}; globalThis.loadTeams = async () => {};
    globalThis.teamRecord = async n => ({ name: n, gen: "8", ok: true, rec: { name: n, access: { users: ["U0AAA1111", "U0BBB2222"], channels: [] } }, text: "" });
    // The record editor holds an unsaved edit (status active): Save access must not post it.
    globalThis.TED = { name: "rusty", gen: "7", ok: true, rec: { name: "rusty", status: "draft", access: { users: ["U0AAA1111"], channels: [] }, repos: [] }, text: JSON.stringify({ name: "rusty", status: "active" }) };
    ACCESS_DRAFT = { team: "rusty", users: "U0AAA1111, U0BBB2222", channels: "", open: false };
    globalThis.fetch = async (url, o) => { calls.push([url, o?.method || "GET", o?.body]); return { ok: true, status: 200, json: async () => ({ ok: true }) }; };
    const p1 = accessSave("rusty"), p2 = accessSave("rusty"); await p1; await p2;
    const posts = calls.filter(c => c[1] === "POST"), body = JSON.parse(posts[0]?.[2] ?? "{}");
    t("access: Save posts the kept record and generation once, with the users added and the rest kept", `${posts.length}|${body.generation}|${body.record?.access?.users?.join(" ")}|${JSON.stringify(body.record?.repos)}`, "1|7|U0AAA1111 U0BBB2222|[]");
    t("access: no GET before the POST", calls[0]?.[1], "POST");
    t("access: unsaved text in the record editor is not posted", body.record?.status, "draft");
    t("access: the status line names the new generation", ACCESS_DRAFT.msg, "saved: generation 8");
    globalThis.fetch = async () => ({ ok: false, status: 409, json: async () => ({ error: "stale" }) }); ACCESS_DRAFT = { team: "rusty", users: "U0CCC3333", channels: "", open: false };
    await accessSave("rusty"); t("access: a stale generation says to load it again", /Someone changed this team after you loaded it/.test(ACCESS_DRAFT.msg), true); }
  RT = { team: "fxa" }; const p = loadRoutines("fxa"); RT = { team: "sync", list: [{ id: 1 }] }; await p;
  t("routines: a list answer for a team the admin left changes nothing", JSON.stringify(RT), JSON.stringify({ team: "sync", list: [{ id: 1 }] }));
  { const calls = []; let done; globalThis.fetch = (url, o) => { calls.push([url, o?.body]); return new Promise(res => { done = () => res({ ok: true, json: async () => ({ out: "created routine 3" }) }); }); };
    globalThis.rtPaint = () => {}; globalThis.document = { getElementById: () => null };
    RT = { team: "fxa", list: [], tpls: [], form: { d: { ...rtDraft(), name: "Code review", repos: ["mozilla/fxa"], channel: "C0123ABCD" }, errs: {} } };
    const a = rtDo("save"), b = rtDo("save"); await Promise.resolve(); done(); globalThis.fetch = async () => ({ ok: true, json: async () => [] }); await Promise.all([a, b]);
    t("routines: a double click on Create sends one POST", calls.filter(c => c[0] === "/api/teams/fxa/routines").length, 1); }
  { const sent = []; let list = [{ id: 4, version: 3, paused: 0, data: { name: "UX review", channel: "C0123ABCD" } }];
    globalThis.fetch = async (url, o) => { if (o?.method === "POST") sent.push([url, JSON.parse(o.body)]);
      if (url.endsWith("/routines/4") && sent.length === 1) return { ok: false, status: 409, json: async () => ({ error: "stale" }) };
      if (url.endsWith("/pause")) list = [{ ...list[0], paused: 1, version: list[0].version + 1 }];
      return { ok: true, status: 200, json: async () => /routines$/.test(url) && o?.method !== "POST" ? list : { out: "ok" } }; };
    RT = { team: "fxa", list, tpls: [], form: { id: 4, version: 2, d: { ...rtDraft(list[0].data), name: "UX review 2" }, errs: {} } };
    await rtDo("save");
    t("routines: after a 409 the draft stays and the form takes the current version", `${RT.form?.d.name}|${RT.form?.version}|${/Save again to replace/.test(RT.msg)}`, "UX review 2|3|true");
    await rtDo("pause", 4);
    t("routines: the admin\u2019s own pause moves the open edit to the new version", RT.form?.version, 4);
    await rtDo("save");
    t("routines: the next Save sends the current version and succeeds", `${JSON.stringify(sent.at(-1))}|${RT.form}`, `${JSON.stringify(["/api/teams/fxa/routines/4", { routine: rtRoutine({ ...rtDraft(list[0].data), name: "UX review 2" }), version: 4 }])}|null`); }
  { const X = "<img src=x onerror=alert(1)></textarea>", team = { profile: "fxa", repos: [{ slug: X, role: "work" }] };
    TEAM_ADMIN = { admin: true };
    RT = { team: "fxa", tpls: [], list: [{ id: 5, version: 1, paused: 0, tick: 1700000000, next: [X],
        live: { state: X, session: X }, last: { state: X, reason: X, pr_url: X },
        data: { name: X, schedule: X, zone: X, channel: X, mode: X, repos: [X], prompt: X } }],
      hist: { 5: [{ started_at: 1, trigger: X, actor: X, state: X, reason: X, pr_url: X, session: X }] },
      msg: X, form: { id: 5, version: 1, d: { ...rtDraft({ name: X, prompt: X, schedule: "daily 09:00", zone: X, channel: X, mode: "report", repos: [X], branch: X }) }, errs: { name: X } } };
    const g = routinesGroup(team, 1700000000);
    t("routines: markup in every field renders inert", `${/<img/.test(g)}|${(g.match(/<\/textarea>/g) ?? []).length}`, "false|1");
    t("routines: the prompt textarea holds the text escaped", g.includes(`>${esc(X)}</textarea>`), true);
    t("routines: History shows a report escaped, in a left-aligned row of its own", /<tr><td colspan="7" style="text-align:left[^"]*"><details data-rt-run="5"><summary>Report<\/summary><pre[^>]*>&lt;b&gt;x&lt;\/b&gt;<\/pre>/.test(rtHist([{ id: 5, started_at: 1, state: "report", report: "<b>x</b>" }])), true);
    RT_OPEN.add("5");
    t("sessions: a routine run names its routine and team, escaped, with a link to the team routines",
      sessRoutineLink({ routine_run: "7", routine_name: "<b>Code review</b>", profile: "fxa" }), `<a href="#teams/routines/fxa">Routine: &lt;b&gt;Code review&lt;/b&gt; (fxa)</a>`);
    t("sessions: a session that is not a routine run has no routine label", sessRoutine({ key: "agent-x" }), "");
    t("routines: an open report stays open on a repaint", rtHist([{ id: 5, started_at: 1, state: "report", report: "x" }]).includes(`<details data-rt-run="5" open>`), true);
    RT_OPEN.clear();
    t("routines: a held report says to read it in History", /held.*History/.test(rtLast({ state: "report", reason: "kept off Slack" }, { channel: "C0123ABCD" })), true);
    t("routines: the report of a routine with no channel is in History", rtLast({ state: "report" }, {}), "report in History");
    t("routines: a queued run of a routine with no channel goes to History only", /result goes to History only/.test(rtState({ live: { state: "queued" }, data: {} })), true);
    t("routines: a routine with no channel shows History only for its channel", rtRow({ id: 1, version: 1, paused: 0, next: [], data: { name: "x", schedule: "daily 09:00", zone: "UTC", mode: "report" } }).includes("none, History only"), true);
    t("routines: a saved routine with no channel edits and saves with no channel", rtRoutine(rtDraft({ name: "x", schedule: "daily 09:00", zone: "UTC", mode: "report", repos: [] })).channel, "");
    t("routines: the channel field says it is optional", /Slack channel \(optional\)/.test(g) && /results show only in History/.test(g), true);
    t("routines: a queued run promises a free runner, not a minute", /starts when a runner is free, within 60 min/.test(rtState({ live: { state: "queued" }, data: { channel: "C0123ABCD" } })), true);
    t("routines: only a GitHub PR URL is a link", [rtLast({ state: "ok", pr_url: "javascript:alert(1)" }), rtLast({ state: "ok", pr_url: "https://evil.example.com/pull/1" }), rtLast({ state: "ok", pr_url: "https://github.com/mozilla/fxa/pull/12" })].map(h => /<a /.test(h)).join(","), "false,false,true"); }
  { const team = { profile: "fxa", repos: [] }, list = { outerHTML: "old list" }, form = { value: "typed" };
    const el = { querySelector: q => q === "[data-routine-form]" ? form : q === "[data-routine-list]" ? list : null };
    RT = { team: "fxa", list: [{ id: 2, version: 1, paused: 0, tick: Date.now() / 1000, next: [], live: { state: "started", session: "agent-ab12" }, data: { name: "Code review", schedule: "daily 09:00", zone: "UTC", channel: "C0123ABCD", mode: "report" } }],
      form: { d: rtDraft(), dirty: true, errs: {} } };
    t("routines: a poll with a dirty form repaints only the list, which turns Running", `${rtKeepForm(el, team)}|${/Running/.test(list.outerHTML)}|${form.value}`, "true|true|typed");
    RT.form.dirty = false; list.outerHTML = "old list";
    t("routines: a clean form lets the whole panel repaint", `${rtKeepForm(el, team)}|${list.outerHTML}`, "false|old list"); }
  { const doc = globalThis.document; let on = "";
    const ctl = (ds, attr) => ({ dataset: ds, closest: q => q === "[data-routines]" ? {} : null, hasAttribute: a => a === attr });
    const del = { disabled: false, focus: () => { on = "delete"; } }, box = { focus: () => { on = "repo"; } }, msg = { focus: () => { on = "msg"; } };
    globalThis.document = { querySelector: q => ({ [`[data-routines] [data-rt-act="delete"][data-rt-id="5"]`]: del, [`[data-routines] [data-rt-repo="mozilla/fxa"]`]: box, "[data-rt-msg]": msg })[q] ?? null };
    const after = (a, gone) => { on = ""; document.activeElement = a; rtFocus(() => { document.activeElement = null; if (gone) del.disabled = true; }); return on; };
    t("routines: a repaint keeps focus on the row button, the repo box, else the status line",
      [after(ctl({ rtAct: "delete", rtId: "5" })), after(ctl({ rtRepo: "mozilla/fxa" })), after(ctl({ rtAct: "delete", rtId: "5" }), true), after(ctl({ rtAct: "pause", rtId: "5" })), after({ dataset: {}, closest: () => null })].join(","),
      "delete,repo,msg,msg,");
    globalThis.document = doc; }
  { const sent = []; globalThis.fetch = async (url, o) => { if (o?.method === "POST") sent.push(`${url} ${o.headers["Content-Type"]} ${o.body}`);
      return { ok: true, status: 200, json: async () => o?.method === "POST" ? { out: "ok" } : [{ id: 6, version: 2, paused: 0, data: { name: "Perf", channel: "C0123ABCD" } }] }; };
    const d = { ...rtDraft(), name: "Perf", repos: ["mozilla/fxa"], channel: "https://x.slack.com/archives/C0123ABCD", branch: "main" };
    RT = { team: "fxa", list: [{ id: 6, version: 2, paused: 0, data: { name: "Perf", channel: "C0123ABCD" } }], tpls: [], form: { d, errs: {} } };
    await rtDo("save");
    RT.form = { id: 6, version: 2, d, errs: {} }; await rtDo("save");
    for (const a of ["run", "stop", "pause", "resume"]) await rtDo(a, 6);
    await rtDo("delete", 6); const armed = sent.length; await rtDo("delete", 6);
    const body = JSON.stringify({ routine: rtRoutine(d) });
    t("routines: each action posts JSON to its route", sent.join("\n"), [`/api/teams/fxa/routines application/json ${body}`, `/api/teams/fxa/routines/6 application/json ${JSON.stringify({ routine: rtRoutine(d), version: 2 })}`,
      ...["run", "stop", "pause", "resume", "delete"].map(a => `/api/teams/fxa/routines/6/${a} application/json {}`)].join("\n"));
    t("routines: the first Delete click only asks", armed, 6);
    t("routines: a branch goes with one repo, and the channel link stays for the server to read", `${rtRoutine(d).branch}|${rtRoutine({ ...d, repos: ["a", "b"] }).branch}|${rtRoutine(d).channel}`, "main|undefined|https://x.slack.com/archives/C0123ABCD"); }
  { const [, sub, sel] = "teams/routines/sync-storage".split("/");
    t("routines: an old #teams/routines/<team> History link opens the team Routines tab", teamRoute(sub, sel).replace, "#teams/sync-storage/routines"); }
  process.exit(fail);
})();
t("agents: a null launchcap says slots unknown, not null", `${agentsMore(false, { launchcap: null })}|${agentsMore(false, null)}|${agentsMore(false, { launchcap: 2 })}`, "slots unknown|slots unknown|2 more may launch");

// Links from feed data (epic i275 slice 1): only a GitHub PR or a session key makes an href.
t("links: a javascript: pr_url and a bad session key make no href", `${prHref("javascript:alert(1)")}|${sessHref("javascript:x")}|${sessHref("agent-ab12")}|${prHref("https://github.com/mozilla/fxa/pull/9")}`, "||#sessions/stopped/agent-ab12|https://github.com/mozilla/fxa/pull/9");
{ const ss = globalThis.AGENTS; globalThis.AGENTS = { sessions: [{ key: "agent-x1", pr_url: "javascript:alert(1)" }] }; t("links: a session whose pr_url is not a PR has no PR link", convPr({ key: "agent-x1", pr_url: "javascript:alert(1)" }), null); globalThis.AGENTS = ss; }
t("links: a run whose session is not a key shows it as text", /href="javascript/.test(rtHist([{ started_at: 1, state: "ok", session: "javascript:alert(1)" }])), false);
// ── the Board (epic i198) ──
{ const now = Math.round(Date.now() / 1000);
  globalThis.STATE = {}; globalThis.SEL = globalThis.SEL || {};
  globalThis.AGENTS = { sessions: [], runners: [{ key: "FXA-20", agent_alive: true, stage: "watching", elapsed_seconds: 600 }, { key: "FXA-21", agent_alive: false, stage: "stalled", detail: "no-motion 30m" }] };
  globalThis.SNAP = { repo: "mozilla/fxa", team: { repo: "mozilla/fxa", jira_site: "https://jira.example.com" }, limits: { attempts: 2 }, inflight: [{ key: "FXA-20" }, { key: "FXA-21" }, { key: "FXA-22", stage: "watching" }],
    blocked: [{ key: "FXA-1", summary: "one", blocked_reason: { kind: "attempts", text: "2 tries", at: now - 7200 } }, { key: "FXA-20", summary: "dup" }, { key: "FXA-2", summary: "<img src=x onerror=alert(1)>" }],
    review: [{ key: "FXA-3", title: "ci", fail: 1 }, { key: "FXA-4", title: "infra", fail: 1, infra: "npm 503" }, { key: "FXA-5", title: "wait", review: "REVIEW_REQUIRED" }],
    queue: { ready: [{ key: "FXA-10", queued_at: now - 3600 }, { key: "FXA-11" }],
      skipped: [{ key: "FXA-6", reason: "pick a route", kind: "needs_decision", last: new Date().toISOString() }, { key: "FXA-7", reason: "held until ../x merges", held_by: "../x" },
                { key: "FXA-8", reason: "underspecified: no criteria" }, { key: "FXA-9", in_queue: false }] } };
  const items = boardItems(), by = k => items.find(i => i.key === k);
  t("board: each key once, and the first place wins (a runner is not also blocked)", `${items.filter(i => i.key === "FXA-20").length}|${by("FXA-20").column}`, "1|running");
  t("board: who acts per kind", ["FXA-1", "FXA-2", "FXA-3", "FXA-4", "FXA-6", "FXA-7", "FXA-8"].map(k => `${by(k).group}:${by(k).person}`).join(" "),
    "act:the operator act:the operator wait:the agent, next pass act:the operator act:the reporter wait:waits on ../x act:the reporter");
  t("board: a PR that waits on a reviewer feeds only the reviewer line", `${by("FXA-5").column}|${/1 PR wait on a reviewer/.test(boardHtml())}`, "review|true");
  t("board: a faulted runner and a run with no sandbox are Running with the operator", `${by("FXA-21").fault}|${by("FXA-22").column}|${by("FXA-22").person}`, "true|running|the operator");
  t("board: the tab count is who must act, plus faulted runs", boardAct(items), 7);
  t("board: every kind has a next step", Object.keys(KIND_LABEL).every(k => classify({ key: "FXA-1", column: "blocked", kind: k }).next.length > 10), true);
  t("board: up next keeps launch order with positions and first queued", `${by("FXA-10").pos}|${by("FXA-11").pos}|${/first queued 1h ago|first queued 60m ago/.test(boardRow(by("FXA-10")))}`, "1|2|true");
  const html = boardHtml();
  t("board: every row with a ticket key links to its rail", (html.match(/class="brow[ "]/g) || []).length === (html.match(/href="#pipeline\/board\/[A-Z]/g) || []).length - (html.match(/waits on <a/g) || []).length, true);
  t("board: a title from Jira is escaped", /<img src=x/.test(html) || !/&lt;img src=x onerror=alert\(1\)&gt;/.test(html), false);
  t("board: a held_by that is not a key has no link", /waits on <a href="#pipeline\/board\/\.\.\/x"/.test(html), false);
  t("board: Waits is a collapsed details with its own count", /<details class="bwait"><summary>Waits \(2\)<\/summary>/.test(html), true);
  globalThis.TAIL_KEYS = ["FXA-20"]; const tk = JSON.stringify(TAIL_KEYS); boardHtml(); t("board: rendering does not touch TAIL_KEYS", JSON.stringify(TAIL_KEYS), tk);
  t("board rail: a ready key shows its position and a Jira link", /10 in launch order|1 in launch order/.test(boardDetails(by("FXA-10"))) && /browse\/FXA-10/.test(boardDetails(by("FXA-10"))), true);
  t("board rail: a blocked key shows its next step", /Fix the PR by hand/.test(boardDetails(by("FXA-1"))), true);
  // The column states: loading, Jira failed, agents failed or stale, empty.
  const snap = SNAP; globalThis.SNAP = null; t("board: before a snapshot each column says loading", (boardHtml().match(/Loading the pipeline/g) || []).length, 3);
  globalThis.SNAP = { ...snap, blocked: null, queue: { ...snap.queue, fetch_failed: true } };
  t("board: a failed Jira read says unknown with no count", `${(boardHtml().match(/unknown, Jira fetch failed/g) || []).length}|${/Blocked<span class="c">0/.test(boardHtml())}`, "2|false");
  globalThis.SNAP = snap; STATE.agents_error = "x"; t("board: a failed agents feed says so", /unknown, agents feed fetch failed/.test(boardHtml()), true);
  STATE.agents_error = ""; STATE.agents_age_seconds = 900; STATE.agents_interval = 60; t("board: a stale agents feed says how old", /unknown, agents feed 15 min old/.test(boardHtml()), true);
  STATE.agents_age_seconds = 10; globalThis.SNAP = { repo: "mozilla/fxa", blocked: [], review: [], inflight: [], queue: { ready: [], skipped: [] } }; globalThis.AGENTS = { sessions: [], runners: [] };
  t("board: empty columns say so", /Nobody needs to act[\s\S]*Nothing is ready[\s\S]*Nothing is running/.test(boardHtml()), true);
  // The gate line (slice 6): first gate wins, never green on an unknown fact.
  { const now = Math.round(Date.now() / 1000), base = () => ({ repo: "mozilla/fxa", blocked: [], review: [], inflight: [], mode: {}, queue: { ready: [1, 2, 3, 4, 5, 6, 7].map(n => ({ key: `FXA-${n}`, queued_at: n < 3 ? now - 600 : null })), skipped: [] },
        health: { launches_24h: 3, max_launches_per_day: 40, lock_stale_seconds: 1800, next_pass_epoch: now + 300, pass_timer: "on", free_gb: 50, min_free_gb: 20 } });
    const gl = (snap, agents = { launchcap: 2, runners: [], sessions: [] }, st = {}) => { globalThis.SNAP = snap; globalThis.AGENTS = agents; globalThis.STATE = { age_seconds: 30, interval: 120, agents_age_seconds: 10, agents_interval: 30, ...st }; return gateLine(now); };
    const g0 = gl(base()); t("gate: clear facts are green and name ticket 1", `${g0.ok}|${/offers FXA-1 first\. Up to 2 can launch/.test(g0.text)}`, "true|true");
    const cases = [
      ["Jira unknown", b => (b.queue.fetch_failed = true, b), /Jira could not be read/],
      ["a stale tickets feed", b => b, /tickets feed is 10 min old/, undefined, { age_seconds: 600 }],
      ["paused", b => (b.health.paused = "maintenance", b), /Passes are paused: maintenance/],
      ["a stale lock", b => (b.health.lock_age_seconds = 2400, b), /A pass lock is 40 min old/],
      ["intake off", b => (b.mode.newtickets = "off", b), /Intake is off/],
      ["low disk", b => (b.health.free_gb = 5, b), /Only 5 GB is free/],
      ["the budget used", b => (b.health.launches_24h = 40, b.health.launch_frees_at = now + 3600, b), /budget is used: 40 of 40\. The next launch is allowed at/],
      ["no budget fact", b => (delete b.health.launches_24h, b), /no launch budget/],
      ["slots unknown", b => b, /Slots unknown/, { launchcap: null, runners: [], sessions: [] }],
      ["no slot", b => b, /No slot is free/, { launchcap: 0, runners: [], sessions: [] }],
      ["the timer off", b => (b.health.pass_timer = "off", b), /pass timer is off/],
      ["9 h to the next pass", b => (b.health.next_pass_epoch = now + 9 * 3600, b), /Outside pass hours/],
      ["nothing ready", b => (b.queue.ready = [], b), /Nothing is ready/] ];
    cases.forEach(([n, f, re, ag, st]) => { const r = gl(f(base()), ag, st); t(`gate: ${n} stops it`, `${r.ok}|${re.test(r.text)}`, "false|true"); });
    const both = base(); both.health.paused = "x"; both.health.free_gb = 1; t("gate: paused wins over a later gate", /Passes are paused/.test(gl(both).text), true);
    const fresh = base(); fresh.health.lock_age_seconds = 120; t("gate: a fresh lock is a pass that runs now", `${gl(fresh).ok}|${/^A pass runs now/.test(gl(fresh).text)}`, "true|true");
    const past = base(); past.health.next_pass_epoch = now - 60; t("gate: a past time is a pass that is due", /a pass is due now \(the snapshot is 1 min old\)/i.test(gl(past).text), true);
    const nt = base(); delete nt.health.next_pass_epoch; t("gate: no next pass time is a note, still green", `${gl(nt).ok}|${/Next pass time unknown/.test(gl(nt).text)}`, "true|true");
    t("gate: no text has a negative time", [g0, gl(past), gl(nt)].some(r => /in -/.test(r.text)), false);
    gl(base()); const h7 = boardHtml();
    t("board: 7 ready rows in order, 2 next pass tags, 2 first queued ages", `${(h7.match(/class="pos">\d+</g) || []).join("").replace(/class="pos">|</g, "")}|${(h7.match(/>next pass</g) || []).length}|${(h7.match(/first queued/g) || []).length}`, "1234567|2|2");
    const gated = base(); gated.health.pass_timer = "off"; gl(gated); t("board: a gate shows no next pass tags", (boardHtml().match(/>next pass</g) || []).length, 0);
    // An old snapshot (no new fields) renders, with only the missing facts unknown.
    const old = { repo: "mozilla/fxa", blocked: [{ key: "FXA-1", summary: "x" }], review: [], inflight: [], queue: { ready: [{ key: "FXA-2" }], skipped: [{ key: "FXA-3", reason: "underspecified: y", last: "2026-10-01T10:00" }] }, health: { lock_held: false } };
    let thrown = ""; try { gl(old); boardHtml(); boardDetails(boardItems()[0]); } catch (e) { thrown = e.message; }
    t("board: an old snapshot renders with no error, blocked in Jira, and an unknown budget", `${thrown}|${boardItems().find(i => i.key === "FXA-1").why}|${/no launch budget/.test(gateLine(now).text)}`, "|blocked in Jira|true"); }
  { globalThis.SNAP = { repo: "mozilla/fxa", blocked: [{ key: "FXA-1", summary: "x", blocked_reason: { kind: "operator", text: "wait for SRE", at: Math.round(Date.now() / 1000) - 3 * 86400 } }], review: [], inflight: [], queue: { ready: [], skipped: [] } };
    globalThis.AGENTS = { runners: [], sessions: [] }; const bi = boardItems()[0];
    t("needs you: a blocked row reads the Board why, who acts and age", needMeta(bi, "old"), "FXA-1 · wait for SRE · the operator · 3d");
    t("needs you: a key the Board does not hold keeps the old text", needMeta(undefined, "FXA-9 · old"), "FXA-9 · old"); }
  { const now = Math.round(Date.now() / 1000);
    globalThis.SNAP = { repo: "mozilla/fxa", blocked: null, review: [], inflight: [], queue: { fetch_failed: true, ready: [], skipped: [] } }; globalThis.AGENTS = { runners: [], sessions: [] }; globalThis.VIEW = "pipeline";
    t("board: a failed Jira read gives no tab count, never 0", tabCount("board"), "");
    globalThis.SNAP = { repo: "mozilla/fxa", blocked: [], review: [], inflight: [], queue: { ready: [], skipped: [
      { key: "FXA-30", reason: "pick", kind: "needs_decision", last: "2026-10-18T09:00", queued_at: now - 20 * 86400 }, { key: "FXA-31", reason: "pick", kind: "needs_decision", last: "2026-10-18T09:00" }] } };
    const it = boardItems(), a30 = it.find(i => i.key === "FXA-30"), a31 = it.find(i => i.key === "FXA-31");
    t("board: a skipped ticket ages from when it was first queued, not from its last skip", `${boardAge(a30.age)}|${a31.age}`, "20d|null"); }
  { const now = Math.round(Date.now() / 1000);
    globalThis.SNAP = { repo: "mozilla/fxa", blocked: [], review: [], inflight: [], mode: {}, queue: { ready: [1, 2, 3, 4, 5].map(n => ({ key: `FXA-${n}` })), skipped: [] },
      health: { launches_24h: 19, max_launches_per_day: 20, lock_stale_seconds: 1800, next_pass_epoch: now + 300, pass_timer: "on", free_gb: 50, min_free_gb: 20 } };
    globalThis.AGENTS = { launchcap: 3, runners: [], sessions: [] }; globalThis.STATE = { age_seconds: 30, interval: 120, agents_age_seconds: 10, agents_interval: 30 };
    t("gate: 1 launch left in the budget says up to 1, and tags 1", `${/Up to 1 can launch/.test(gateLine(now).text)}|${(boardHtml().match(/>next pass</g) || []).length}`, "true|1"); }
  t("board: the Board tab is off, and Pipeline opens on Belts", VIEWS.find(v => v[0] === "pipeline")[3].map(x => x[0]).join(","), "belts,queue,done"); }
JS
