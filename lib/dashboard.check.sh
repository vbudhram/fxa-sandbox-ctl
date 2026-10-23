#!/usr/bin/env bash
# Offline check of the dashboard's helpers: session titles, owners, conversation counts, Slack PR belts, the outcome card, Needs you counts, queue groups.
#   bash lib/dashboard.check.sh
set -u
command -v node >/dev/null || { echo "skip: needs node"; exit 0; }
page="$(dirname "$0")/../dashboard/index.html"
# The JS reads from a quoted heredoc, so an apostrophe in it is safe.
fns="$(sed -n '/^const esc = /p; /^\/\/ Components:/,/^\/\/ End components\./p; /^const days = /p; /^const plainMd = /p; /^const queueWaits = /p; /^function ownerName(s) {/,/^}/p; /^const sessTabOf = /p; /^const sessRoutine = /p; /^const sessRoutineLink = /p; /^const teamName = /p; /^const teamLabel = /p; /^const sessLink = /p; /^const convTitle = /p; /^const sessSummary = /p; /^function outcomeHtml(s) {/,/^}/p; /^function merged() {/,/^}/p; /^function laneRows() {/,/^}/p; /^function firstLine(t) {/,/^}/p; /^function sessDay(c) {/,/^}/p; /^let STAT_USD/p; /^function sessUsd(s) {/,/^}/p; /^function slackText(t) {/,/^}/p; /^const ageOf = /p; /^function convPr(s) {/,/^}/p; /^function skipGroups(ks) {/,/^}/p; /^const inRange = /p; /^function teamUse() {/,/^}/p; /^function sessHeads(ss) {/,/^}/p; /^function chainOf(s, ss) {/,/^}/p; /^const kvr = /p; /^const stamp = /p; /^const usd = /p; /^let RT = /p; /^const RT_/p; /^function rtDraft(/,/^}/p; /^function rtRoutine(/,/^}/p; /^function rtErrs(/,/^}/p; /^const rtWhen = /p; /^const rtSched = /p; /^function rtState(/,/^}/p; /^function rtFix(/,/^}/p; /^function rtFromTpl(/,/^}/p; /^function rtSays(/,/^}/p; /^function rtResult(/,/^}/p; /^function rtDetail(/,/^}/p; /^function rtCard(/,/^}/p; /^function rtNextDays(/,/^}/p; /^function rtReadback(/,/^}/p; /^function rtCostHint(/,/^}/p; /^function rtChannelField(/,/^}/p; /^function rtEnsureHist(/,/^}/p; /^const rtIn = /p; /^const sentence = /p; /^const rtZoneName = /p; /^const rtChName = /p; /^const rtGlyph = /p; /^const rtStat = /p; /^const rtStarts = /p; /^const rtSteps = /p; /^const rtNextText = /p; /^function rtHist(/,/^}/p; /^function routineListHtml(/,/^}/p; /^function routineForm(/,/^}/p; /^function routinesGroup(/,/^}/p; /^function teamDetails(t) {/,/^}/p; /^const kvr = /p; /^let TAB/p; /^async function loadRoutines(/,/^}/p; /^async function rtDo(/,/^}/p; /^function rtKeepForm(/,/^}/p; /^function rtFocus(/,/^}/p; /^const rtSay = /p; /^const rtPr = /p; /^const prHref = /p; /^const sessHref = /p; /^const VIEWS = \[/,/^\];/p' "$page"; sed -n '/^const agentsMore = /p; /^const KEY_RE = /p; /^const TEAM_RE = /p; /^const LIVE_SESSION = /p; /^let TTAB = /p; /^const TTABS = /p; /^function teamRoute(/,/^}/p; /^const rtFailed = /p; /^async function rtLoadHist(/,/^}/p; /^const rtSum = /p; /^const spendSkip = /p; /^const teamNeeds = /p; /^function teamReason(/,/^}/p; /^function teamItem(/,/^}/p; /^function teamErrs(/,/^}/p; /^function teamWeek(/,/^}/p; /^function budgetCell(t) {/,/^}/p; /^function testCell(t) {/,/^}/p; /^function allTeamsHtml(/,/^}/p; /^function teamSettingsHtml(/,/^}/p; /^function teamPageHtml(/,/^}/p; /^const accessList = /p; /^function teamBanner(/,/^}/p; /^function teamRecent(/,/^}/p; /^function teamActivity(/,/^}/p; /^function teamReadiness(/,/^}/p; /^function teamOverview(/,/^}/p; /^const teamLevel = /p; /^const teamBadge = /p; /^const teamAccess = /,/;$/p; /^const NEXT_STEP = {/,/^};/p; /^const KIND_LABEL = {/,/fault: "fault" }/p; /^const skipKindOf = /p; /^const boardAge = /p; /^const secsSince = /p; /^function classify(i) {/,/^}/p; /^function boardItems() {/,/^}/p; /^function gateLine(/,/^}/p; /^const boardAct = /p; /^function boardState(col) {/,/^}/p; /^function tabCount(t) {/,/^}/p;' "$page"; sed -n '/^const FIREFOX_READ = /p; /^function teamRunsOn(/,/^}/p; /^const repoShip = /p; /^const teamTools = /p; /^const TEAM_RUNNER_KEYS = /p; /^let TFORM = /p; /^const teamDraftOf = /p; /^const teamCap = /p; /^const teamRetest = /p; /^const newTeamReadback = /p; /^function teamWho(/,/^}/p; /^function teamTestState(/,/^}/p; /^function teamStateTag(/,/^}/p; /^function teamRepoSays(/,/^}/p; /^function teamTestCard(/,/^}/p; /^let TOPTS = /p; /^const personLabel = /p; /^const list0 = /p; /^function peoplePicker(/,/^}/p; /^function teamItemForm(/,/^}/p; /^function teamItemDraft(/,/^}/p; /^function teamApply(/,/^}/p; /^function teamPatch(/,/^}/p; /^function teamSetupHtml(/,/^}/p; /^function newTeamHtml(/,/^}/p; /^function newTeamRecord(/,/^}/p; /^function newTeamErrs(/,/^}/p; /^function teamProblem(/,/^}/p; /^function teamInfoHtml(/,/^}/p;  /^let TACT = /p; /^async function teamPost(/,/^}/p; /^async function teamItemSave(/,/^}/p; /^async function teamTestStart(/,/^}/p; /^async function teamTestPoll(/,/^}/p; /^async function teamCreate(/,/^}/p; /^function teamPaint(/,/^}/p; /^let TEAM_ADMIN = /p;' "$page"; sed -n '/^const REPO_RE = /p; /^function safeRender(/,/^}/p; /^function teamRepo() /p; /^function jiraHref(/p; /^function prUrl(/p; /^const ago = /,/^const short = /p; /^const LANE_ST = /p; /^const LANE_OUT = /p; /^function laneTitle(/,/^}/p; /^function openPrCounts(/,/^}/p; /^let OUTSIDE_OPEN/p; /^const BELT_GROUPS = /,/\]\];$/p; /^const BROKEN = /p; /^const BELT_PHASES = /p; /^const BELT_SUBS = /,/\]\];$/p; /^function beltGroups(/,/^}/p; /^const beltCount = /p; /^const BRAND = /p; /^const brandSvg = /p; /^const srcBadge = /p; /^const statTile = /p; /^const strokeSvg = /p; /^const BELT_HINT = /,/\] };$/p; /^const beltTone = /p; /^function beltRow(/,/^}/p; /^function beltsHtml(/,/^}/p; /^function beltDetails(/,/^}/p; /^function beltWhere(/,/^}/p; /^function doneRows() {/,/^}/p; /^const jira = /p; /^const prl = /p; /^function doneHtml(/,/^}/p' "$page")"
# The code goes in a file: Linux refuses one argument over 128 KB (exit 126), which the code passed.
fnsf="$(mktemp "${TMPDIR:-/tmp}/dashboard-check.XXXXXX")"; trap 'rm -f "$fnsf"' EXIT; printf '%s' "$fns" > "$fnsf"
node - "$fnsf" "$page" <<'JS'
process.argv.splice(1, 1);  // node - puts "-" at argv[1]
eval(require("fs").readFileSync(process.argv[1], "utf8").replace(/^(let|const) /gm, "var "));  // a top-level let or const in eval would stay inside it
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
  t("routines: an open form keeps the dirty draft on a repaint", /value="My unsaved name"/.test(g), true);
  t("routines: a live run shows Running and its session in the list", /Running<\/span> <a class="mono" href="#sessions\/live\/agent-ab12"/.test(routineListHtml(team, now)), true);
  const form = RT.form; RT.form = null;
  t("routines: a live run turns Run now off on its card", /data-rt-act="run" data-rt-id="2"[^>]*disabled/.test(routineListHtml(team, now)), true);
  RT.sel = 2; t("routines: a live run turns Run now off on its page", /class="rtd[\s\S]*data-rt-act="run" data-rt-id="2"[^>]*disabled/.test(routinesGroup(team, now)), true); RT.sel = undefined; RT.form = form;
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
  const btns = String(rtDetail(team, RT.list[0])).match(/<button [^>]*>/g) ?? [];
  t("routines: each button on a routine's page has an aria-label that names the routine", btns.length >= 5 && btns.every(b => /aria-label="[^"]* UX review"/.test(b)), true); }
t("routines: a routine's page stacks its two columns under 900px", /@media \(max-width:900px\) \{ \.rtcols \{ grid-template-columns:minmax\(0,1fr\); \} \}/.test(require("fs").readFileSync(process.argv[2], "utf8")), true);
{ globalThis.teamUsage = () => ""; globalThis.teamEditor = () => ""; globalThis.closeBtn = ""; globalThis.teamName = x => x.label || x.profile; globalThis.repoShip = () => ["ok", "", ""];
  globalThis.teamTools = () => "none"; globalThis.TEAMS = { teams: [{ profile: "fxa", repos: [], issues: [] }] }; globalThis.TEAM_ADMIN = { admin: true };
  const p = "echo $1 and $$HOME $& $` $\u0027 done";
  RT = { team: "fxa", list: [], tpls: [], form: { d: { ...rtDraft(), prompt: p }, errs: {}, dirty: true } };
  TTAB = "routines"; const h = String(teamPageHtml("fxa"));
  t("routines (Routines tab): a prompt with $ patterns renders unchanged", h.includes(`>${esc(p)}</textarea>`), true);
  t("routines: the Routines tab holds the routines group", h.includes("data-routines"), true);
  globalThis.TEAM_ADMIN = { admin: false }; t("routines: a viewer who is not an admin sees no routines", /Only a team admin can see and change routines/.test(teamPageHtml("fxa")) && !String(teamPageHtml("fxa")).includes("data-routines"), true);
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
  globalThis.ERRS = null; globalThis.STATS = null; const all = String(allTeamsHtml());
  t("all teams: four tiles and one row per team, names escaped", `${(all.match(/class="[^"]*\bstat\b/g) || []).length}|${(all.match(/<tr><td><a /g) || []).length}|${/<img src=x>/.test(all)}`, "4|3|false");
  t("all teams: a cost no team reports shows a dash, never a zero", /Cost this month<\/span><span class="big">—</.test(all), true);
  t("all teams: an admin gets New team at the top, and a card for the team that is not set up", `${/<a class="btn" href="#teams\/new" data-team-new>New team/.test(all)}|${/href="#teams\/ent\/settings"[^]*Off\. Test it to turn it on again/.test(all)}`, "true|true");
  const appInfo = { profile: "x", issues: [{ level: "info", text: "org/repo: the agent's GitHub App is not installed on it" }, { level: "info", text: "something else" }] };
  t("all teams: an info missing App shows App missing with the repo, and does not need attention", `${/App missing<\/span> <span class="mono na">org\/repo</.test(teamProblem(appInfo))}|${/none/.test(teamProblem({ issues: [{ level: "info", text: "something else" }] }))}|${!!teamNeeds(appInfo)}`, "true|true|false");
  TTAB = "overview"; const pg = String(teamPageHtml("ent"));
  t("team page: a team that is not active has a heading to focus, and only Settings and Routines", `${/<h2 class="th" id="team-h" tabindex="-1">Entitlements/.test(pg)}|${(pg.match(/class="ttab"/g) || []).length}|${/href="#teams\/ent\/routines"/.test(pg)}`, "true|2|true");
  t("team page: a team that is not active opens on Settings, with the step left", /href="#teams\/ent\/settings" aria-current="page">Settings<span class="n">1 left/.test(pg), true);
  t("team page: an active team has four tabs, Memory among them", (String(teamPageHtml("crew")).match(/class="ttab"[^>]*>(Overview|Routines|Memory|Settings)/g) || []).length, 4);
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
    t("overview: the cost card shows this month against the cap", /\$1,?041\.09.*of \$1,?500/.test(String(teamOverview(fx)).replace(/\s+/g, " ")), true);
    t("overview: unreadable spend says so, never $0", /budget unknown: the spend file cannot be read/.test(teamOverview({ ...fx, budget: null, budget_error: "unreadable" })), true);
    t("overview: a healthy team has a one-line Readiness", /3 of 3 good/.test(teamReadiness(fx)), true);
    t("overview: access that cannot be read is unknown, not good", /<b>Access<\/b>[^]*?class="tag">unknown/.test(teamReadiness({ ...fx, profile: "crew", access: null })), true);
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
    const rows = show => { RT.show = show; return (String(routineListHtml({ profile: "fxa" }, Date.now() / 1000)).match(/data-rt-sel="\d+">[A-Za-z]+/g) || []).map(x => x.replace(/.*>/, "")).join(","); };
    t("routines tab: Show all, failed and paused", `${rows("all")}|${rows("failed")}|${rows("paused")}`, "Alpha,Beta,Gamma|Beta|Gamma");
    RT.show = "all"; const h = routineListHtml({ profile: "fxa" }, Date.now() / 1000);
    t("routines tab: the On switch posts pause or resume, with aria-pressed and a label", `${/data-rt-act="pause" data-rt-id="1" aria-pressed="true" aria-label="Routine Alpha on"/.test(h)}|${/data-rt-act="resume" data-rt-id="3" aria-pressed="false"/.test(h)}`, "true|true");
    t("routines tab: with no routine picked it opens on the list", `${/data-routine-list/.test(routinesGroup({ profile: "fxa" }, Date.now() / 1000))}|${/class="rtd/.test(routinesGroup({ profile: "fxa" }, Date.now() / 1000))}`, "true|false");
    RT.sel = 3; t("routines tab: a picked routine opens its page", /class="rtd[\s\S]*<h3 class="nm">Gamma/.test(routinesGroup({ profile: "fxa" }, Date.now() / 1000)), true);
    RT.sel = 99; t("routines tab: a picked routine that is gone shows the list and says so", /The routine from the link is no longer here/.test(routinesGroup({ profile: "fxa" }, Date.now() / 1000)), true);
    RT.sel = 2; RT.histErr = { 2: "HTTP 500" }; t("routines tab: runs that did not load say so, with Retry", /Runs did not load: HTTP 500 <button data-rt-act="hist" data-rt-id="2">Retry/.test(routinesGroup({ profile: "fxa" }, Date.now() / 1000)), true); RT.sel = undefined;
    RT.list[0].recent = [{ state: "failed" }, { state: "ok" }];
    t("routines tab: the last runs are dots, oldest first, named for a screen reader", /aria-label="Oldest first: failed, draft pr"><span class="dot bad"[^>]*><\/span><span class="dot done"/.test(routineListHtml({ profile: "fxa" }, Date.now() / 1000)), true);
    RT = { team: null }; }
  // Settings and Access (slice 7)
  { globalThis.TEAM_ADMIN = { admin: true };
    const fx = { profile: "fxa", repos: [], issues: [], access: { open: "built-in" } }, env = { profile: "pyfxa", repos: [], issues: [], access: { open: false, users: 2, channels: 0, jira: [] } };
    t("settings: FxA and an env team are read-only, and say who changes them", `${/<input/.test(teamSettingsHtml(fx))}|${/<input/.test(teamSettingsHtml(env))}|${/The operator changes this team in profiles\/pyfxa\//.test(teamSettingsHtml(env))}`, "false|false|true");
    const rt = { profile: "rusty", repos: [], issues: [], access: { record: true, status: "active", open: false, users: 1, channels: 0, jira: [] } };
    globalThis.TED = { name: "rusty", gen: "7", ok: true, rec: { name: "rusty", status: "active", access: { users: ["U0AAA1111"], channels: [] } }, text: "{}" }; TFORM = { team: "rusty", item: "access", d: teamItemDraft("access", TED.rec) };
    t("settings: the people form lists each person of the record with Remove, and a search", /data-tfunpick="users" data-id="U0AAA1111"/.test(teamSetupHtml(rt)) && /data-tfpq="users"/.test(teamSetupHtml(rt)), true);
    t("settings: a change to people on an active team needs no new test", /Save and test again/.test(teamSetupHtml(rt)), false);
    TFORM = { team: "rusty", item: "repos", d: { repos: [{ slug: "a/b", role: "work" }] } };
    t("settings: a change to repos on an active team says first that it needs a new test", /This change needs a new test[^]*Save and test again/.test(teamSetupHtml(rt)), true); TFORM = null;
    globalThis.TEAM_ADMIN = { admin: false }; t("settings: a viewer who is not an admin gets no form", `${/A team admin changes this team/.test(teamSettingsHtml(rt))}|${/<input|<textarea/.test(teamSettingsHtml(rt))}`, "true|false"); globalThis.TEAM_ADMIN = { admin: true };
    globalThis.TED = { name: "rusty", ok: false, msg: "HTTP 500" }; t("settings: a record that did not load says so, with no form", `${/The record did not load: HTTP 500/.test(teamSetupHtml(rt))}|${/id="tf-/.test(teamSetupHtml(rt))}`, "true|false");
    globalThis.TED = { name: "rusty", gen: "7", ok: true, rec: { name: "rusty", access: {} } };
    { const full = { name: "rusty", status: "active", label: "Rusty (web)", admins: [{ slack: "U0AAA1111", email: "a@example.com" }], access: { open: false, users: ["U0AAA1111"], channels: ["C0AAA1111"], jira_prefixes: ["RUS"] },
        repos: [{ slug: "mozilla/fxa", role: "work", default: true }, { slug: "o/r", role: "dep" }], stack: { kind: "fxa" }, runner: { backend: "firecracker", android: true, desktop_url: "http://localhost:3030/" },
        egress: { requested: ["a.example.com"], approved: ["b.example.com"] }, mcp: ["jira"], jira: { project: "RUS", queue: true }, caps: { usd_per_day: 5 }, pr: { open: true, reviewers: ["t"] },
        prompts: { goal_md: "g" }, skills: ["fxa-stack"], boot: { script: "s", sha256: "a".repeat(64) }, secrets: { jira: "fxa-team-rusty--jira", runtime: [{ secret: "fxa-team-rusty--env", path: "/home/agent/fxa/.env" }] } };
      const keep = TED; globalThis.TED = { name: "rusty", rec: full }; globalThis.TOPTS = { boot: [{ script: "s", sha256: "a".repeat(64) }] };
      const same = ["name", "admins", "access", "jira", "tools", "caps", "pr", "runner", "egress", "skills", "boot", "secrets"].filter(i => { const after = teamApply(full, teamPatch({ item: i, d: teamItemDraft(i, full) }));
        return JSON.stringify(after) !== JSON.stringify(full); });
      t("settings: every item opened and saved unchanged leaves the record as it was", same.join(","), "");
      const bare = { name: "rusty", repos: [{ slug: "o/r", role: "work" }] }; globalThis.TED = { name: "rusty", rec: bare };
      t("settings: a record with no runner keys gets none from an unchanged save", ["runner", "egress", "skills", "boot", "secrets", "admins", "name"].filter(i => teamRetest(bare, teamApply(bare, teamPatch({ item: i, d: teamItemDraft(i, bare) })))).join(","), "");
      t("settings: secret names get the team's prefix, and a pick of the FxA stack names no repo for mozilla/fxa", JSON.stringify([teamPatch({ item: "secrets", d: { jira: "login", runtime: [{ what: "env", path: "/home/agent/r/.env" }, { what: "", path: "" }] } }).secrets,
        teamPatch({ item: "runner", d: { kind: "fxa", srepo: "mozilla/fxa", backend: "gce", android: false, desktop_url: "" } })]),
        JSON.stringify([{ jira: "fxa-team-rusty--login", runtime: [{ secret: "fxa-team-rusty--env", path: "/home/agent/r/.env" }] }, { stack: { kind: "fxa" } }]));
      globalThis.TED = keep; globalThis.TOPTS = null; }
    t("settings: a people list keeps each ID once", teamPatch({ item: "access", d: { open: false, users: "U1, U2  U1,,U3", chans: [], other: "" } }).access.users.join(" "), "U1 U2 U3");
    t("settings: a removed tools list goes back to the bot default", "mcp" in teamApply({ mcp: ["x"] }, teamPatch({ item: "tools", d: { dflt: true, mcp: "" } })), false);
    t("new team: the record has the work repo, the stack, the goal and the label", JSON.stringify(newTeamRecord({ name: "relay", repo: "mozilla/fx-private-relay", stack: "none", goal: "g" })),
      JSON.stringify({ schema: 1, name: "relay", label: "Relay", status: "draft", repos: [{ slug: "mozilla/fx-private-relay", role: "work", default: true }], stack: { kind: "none" }, access: { open: true, users: [], channels: [], jira_prefixes: [] }, prompts: { goal_md: "g" } }));
    t("new team: the FxA stack adds its mozilla/fxa repo", JSON.stringify(newTeamRecord({ name: "pay", repo: "acme/pay", stack: "fxa", goal: "" }).repos[1]), JSON.stringify({ slug: "mozilla/fxa", role: "dep" }));
    t("new team: the validator's lines go to their fields", JSON.stringify(newTeamErrs("ERROR: x.json: repos[0].slug: acme is not valid\na team without the FxA stack needs prompts.goal_md: why\nsomething else").errs), JSON.stringify({ repo: "repos[0].slug: acme is not valid", goal: "a team without the FxA stack needs prompts.goal_md: why" }));
    globalThis.NEWT = { name: "<b>x</b>", repo: "", stack: "", goal: "", errs: {} }; t("new team: the form escapes what was typed", /<b>x<\/b>/.test(String(newTeamHtml())), false); globalThis.NEWT = null; }
  { globalThis.TEAM_ADMIN = { admin: true }; RTSUM = { teams: { solo: { routines: 1, failed: 0 } } };
    const solo = { profile: "solo", repos: [], issues: [{ level: "info", text: "spend cannot be read" }], access: { open: true } };
    t("teams: unreadable spend with routines needs attention, with the reason and a warn badge", `${teamNeeds(solo)}|${teamReason(solo)}|${teamBadge([solo])}`, "true|routines are skipped: the team\u0027s spend cannot be read · 1 routine| warn");
    RTSUM = null; t("teams: without routines it stays under Teams", `${teamNeeds(solo)}|${teamBadge([solo])}`, "false|"); }
  t("last test: a pass at the current generation with no log", String(testCell({ access: { record: true, status: "active" }, test: { result: null, tested: 14, generation: 14 } })), "\u003cspan class=\"tag ok\">passed\u003c/span>");
  t("last test: an active team keeps its pass after edits a runner never reads", /passed/.test(testCell({ access: { record: true, status: "active" }, test: { result: null, tested: 12, generation: 13 } })), true);
  t("last test: a draft with an older pass is not tested", /not tested/.test(testCell({ access: { record: true, status: "draft" }, test: { result: null, tested: 2, generation: 3 } })), true);
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
  const load = () => { globalThis.SNAP = JSON.parse(JSON.stringify(fx.snapshot)); globalThis.AGENTS = JSON.parse(JSON.stringify(fx.agents)); globalThis.STATE = { agents_age_seconds: 20, agents_interval: 30 }; globalThis.TEAM_ADMIN = { admin: false }; globalThis.SEL = {}; globalThis.TAB = "belts"; };
  load(); const g = beltGroups(), keys = k => g[k].map(r => r.t.key).join(",");
  t("belts: groups and keys", ["working", "needs", "fixes", "review", "outside"].map(keys).join(" | "), "FXA-20,FXA-21 | FXA-1 | FXA-4,FXA-3 | FXA-10,FXA-11,FXA-22 | agent-abc123,FXA-41");
  const all = ["working", "needs", "fixes", "review", "outside"].flatMap(k => g[k].map(r => r.t.key));
  t("belts: each key once; a hold, a ready ticket and a merged PR have no belt", `${new Set(all).size === all.length}|${["FXA-7", "FXA-30", "FXA-12"].some(k => all.includes(k))}`, "true|false");
  t("belts: Needs you equals boardAct, and the belt count is the four groups", `${g.needs.length === boardAct(boardItems())}|${beltCount(g)}`, "true|8");
  t("belts: the CI running PR waits on review, and the outside rows name their source", `${g.review.find(r => r.t.key === "FXA-22").l1}|${g.outside.map(r => r.l1).join(";")}`, "CI running|Slack · Sample Person's session;Not in the pipeline");
  const h = String(beltsHtml(g)), order = [...h.matchAll(/<h2 class="bgh"[^>]*>([^<]+) <span class="cnt">(\d+)|<h3 class="bsub">[\s\S]*?<span class="who">(\w+)<\/span>([^<]+) <span class="cnt">(\d+)/g)].map(m => m[1] ? `${m[1]} ${m[2]}:` : `${m[3]}/${m[4]} ${m[5]}`).join(" ");
  t("belts: phases closest to the merge first, then who acts, with counts", order, "PR 5: You/Review and merge 3 Agent/The agent fixes it, next pass 2 Agent run 2: Agent/Working now 2 Queue 1: You/Decide 1");
  t("belts: green is CI passed, red is broken, amber is a decision", ["working", "needs", "fixes", "review"].flatMap(k => g[k]).map(r => `${r.t.key}=${r.tone}`).join(","), "FXA-20=k-live,FXA-21=k-live,FXA-1=k-warn,FXA-4=k-bad,FXA-3=k-bad,FXA-10=k-ok,FXA-11=k-ok,FXA-22=k-live");
  t("belts: the header line", /Needs you<\/span><span class="big">4</.test(h) && /3 to review · 1 to decide or fix/.test(h) && /Agents working<\/span><span class="big">2</.test(h) && /8 belts in all/.test(h), true);
  const row = k => String(beltRow(["working", "needs", "fixes", "review"].flatMap(x => g[x]).find(r => r.t.key === k)));
  const f3 = row("FXA-3"), f20 = row("FXA-20");
  t("belts: the Jira key and the PR number open their pages from the closed row", `${/class="key mono" data-href="https:\/\/jira\.example\.com\/browse\/FXA-3"/.test(f3)}|${/data-href="https:\/\/github\.com\/example\/app\/pull\/3"/.test(f3)}`, "true|true");
  t("belts: track nodes, stop text and no callout", `${(f3.match(/class="n done"/g) || []).length}|${(f3.match(/class="n cur"/g) || []).length}|${(f3.match(/class="n"/g) || []).length}|${/aria-hidden="true">/.test(f3)}|${/Stop 7 of 9, CI</.test(f3)}|${/class="mark"/.test(h)}`, "6|1|2|true|true|false");
  t("belts: a live agent pulses and says so; its terminal is in its open details", `${/class="n cur live"/.test(f20)}|${/Stop 3 of 9, Agent, agent working/.test(f20)}|${/Agent · 12 min/.test(f20)}|${/yarn test example-server/.test(f20)}|${/lane-term/.test(f20)}|${(SEL.pipeline = "FXA-20", /id="lane-term-FXA-20"/.test(row("FXA-20")))}`, "true|true|true|true|false|true"); SEL.pipeline = "";
  load(); SNAP.blocked[0].summary = "<img src=x onerror=alert(1)>"; AGENTS.runners[0].agent.last_tool = "<img src=x>"; const hx = beltsHtml(beltGroups());
  t("belts: text from feeds is escaped", `${/&lt;img/.test(hx)}|${/<img src=x/.test(hx)}`, "true|false");
  load(); SNAP.review[0].infra = "<img src=x>"; SNAP.review[0].fail = 1; SEL.pipeline = "FXA-3"; const gd = beltGroups(), dh = String(beltDetails([...gd.needs, ...gd.fixes].find(r => r.t.key === "FXA-3"))), oh = String(beltsHtml(gd));
  t("belts: an infra red PR needs a person under Fix it, in red", `${gd.needs.find(r => r.t.key === "FXA-3")?.tone}|${/<span class="who">You<\/span>Fix it <span class="cnt">1</.test(oh)}`, "k-bad|true");
  t("belt details: escaped, with the failing check as the main action, and only the open row has details", `${/&lt;img/.test(dh)}|${/<img src=x/.test(dh)}|${/class="main"[^>]*href="https:\/\/github.com\/example\/app\/pull\/3\/checks"/.test(dh)}|${(oh.match(/class="bdet"/g) || []).length}`, "true|false|true|1");
  load(); SNAP.open_prs.push({ number: 7, key: "FXA-1", title: "x", created: "2026-10-15T10:00:00Z", branch: "FXA-1" }); const gb = beltGroups(), b1 = gb.needs.find(r => r.t.key === "FXA-1");
  t("belt details: a Jira-blocked ticket with an open PR answers in Jira", `${b1.t.pr}|${/class="main"[^>]*href="https:\/\/jira\.example\.com\/browse\/FXA-1"[^>]*>Answer in Jira</.test(beltDetails(b1))}`, "7|true");
  load(); SNAP.review[0].mergeable = "CONFLICTING"; SNAP.review[0].relock_failed = "FXA-3 7 CONFLICT lockfile (relock FAILED; run: relock FXA-3)";
  const ir = boardItems().map(classify).find(i => i.key === SNAP.review[0].key);
  t("belts: a conflict whose relock failed waits on the operator with the relock command, not on the next pass", `${ir.kind}|${ir.person}|${ir.group}|${/relock FXA-3 on the manager/.test(ir.next)}`, "relock|the operator|act|true");
  load(); const st0 = { ...STATE }; Object.assign(STATE, { age_seconds: 3600, interval: 300 });
  t("belts: an old snapshot makes every column unknown, Needs you included", `${/snapshot is 60 min old/.test(boardState("needs"))}|${/snapshot is 60 min old/.test(boardState("running"))}`, "true|true");
  Object.keys(STATE).forEach(k => delete STATE[k]); Object.assign(STATE, st0);
  load(); SNAP.inflight_prs_failed = true; const gi = beltGroups();
  t("belts: a failed in-flight PR read makes fixes and review unknown, from GitHub", `${gi.unknown.fixes}|${gi.unknown.review}|${beltCount(gi)}`, "unknown, GitHub fetch failed|unknown, GitHub fetch failed|null");
  const hi = String(beltsHtml(gi));
  t("belts: with a feed unknown, no phase heading gives a confident count", `${[...hi.matchAll(/<h2 class="bgh"[^>]*>[^<]+ <span class="cnt">([^<]+)</g)].every(m => m[1] === "?")}|${/<h2 class="bgh"/.test(hi)}`, "true|true");
  load(); AGENTS.runners[0].agent_alive = false; const gx = beltGroups();
  t("belts: an agent that exited with no handoff needs a person, and is not counted as working", `${gx.working.map(r => r.t.key).join(",")}|${gx.needs.some(r => r.t.key === "FXA-20")}|${gx.needs.length === boardAct(boardItems())}|${/Agents working<\/span><span class="big">1</.test(beltsHtml(gx))}`, "FXA-21|true|true|true");
  load(); SNAP.review = null; const gr = beltGroups(); SNAP.done_fetch_failed = true; const gj = beltGroups();
  t("belts: a null review list names GitHub, or Jira when the done read failed", `${gr.unknown.review}|${gj.unknown.review}`, "unknown, GitHub fetch failed|unknown, Jira fetch failed");
  load(); SNAP.inflight_fetch_failed = true; SNAP.inflight_prs_failed = true; const gf = beltGroups();
  t("belts: a failed in-flight Jira read names Jira", `${gf.unknown.fixes}|${gf.unknown.review}`, "unknown, Jira fetch failed|unknown, Jira fetch failed");
  load(); AGENTS.sessions[0].state = "paused"; const so = beltGroups().outside.find(r => r.t.slack), sd = String(beltDetails(so));
  t("belt details: a Slack belt opens its session on the session's own tab", `${/class="main"[^>]*href="#sessions\/paused\/agent-abc123"/.test(sd)}|${/#sessions\/stopped\//.test(sd)}`, "true|false");
  load(); SNAP.review = null; SNAP.done_fetch_failed = true; const gn = beltGroups(), hn = beltsHtml(gn);
  t("belts: with no review list, a pipeline PR is never called outside the pipeline", `${gn.outside.filter(r => !r.t.slack).map(r => r.l1).join(",")}|${/not in the pipeline/i.test(hn)}|${/state unknown/.test(hn)}`, "State unknown,State unknown|false|true");
  load(); SNAP.inflight_fetch_failed = true; const gk = beltGroups();
  t("belts: a failed in-flight read keeps a stray PR on the page as State unknown, and the PR count agrees", `${gk.outside.find(r => r.t.key === "FXA-41")?.l1}|${/not in the pipeline/.test(openPrCounts().parts)}`, "State unknown|false");
  SEL.pipeline = ""; globalThis.BAD_LINK = true; t("a bad pipeline link says so and echoes nothing", /That link names no ticket\./.test(beltsHtml(beltGroups())), true); globalThis.BAD_LINK = false;
  load(); SNAP.inflight = []; SNAP.review = []; SNAP.blocked = []; SNAP.queue.skipped = []; SNAP.queue.ready = []; SNAP.open_prs = []; AGENTS.runners = []; AGENTS.sessions = [];
  const ge = beltGroups(), he = String(beltsHtml(ge));
  t("belts: an empty page says so, with no Outside group", `${he.includes("Nothing on the belts.")}|${/bout/.test(he)}|${beltCount(ge)}`, "true|false|0");
  const unk = [() => { globalThis.SNAP = null; }, () => { SNAP.queue.fetch_failed = true; SNAP.blocked = null; }, () => { SNAP.review = null; SNAP.open_prs = null; }, () => { SNAP.review = null; SNAP.done_fetch_failed = true; },
    () => { STATE.agents_error = "x"; }, () => { STATE.agents_age_seconds = 900; STATE.agents_interval = 60; }].map(f => { load(); f(); const gg = beltGroups(), hh = String(beltsHtml(gg)); return [hh, beltCount(gg)]; });
  t("belts: before a snapshot, loading with no counts", `${/Loading the pipeline/.test(unk[0][0])}|${/\d belts/.test(unk[0][0])}`, "true|false");
  t("belts: an unknown feed shows ? and its reason, never 0", [
    /unknown, Jira fetch failed/.test(unk[1][0]) && /Needs you<\/span><span class="big">\?/.test(unk[1][0]),
    (unk[2][0].match(/unknown, GitHub fetch failed/g) || []).length === 2,
    (unk[3][0].match(/unknown, Jira fetch failed/g) || []).length === 2,
    /unknown, agents feed fetch failed/.test(unk[4][0]) && /Agents working<\/span><span class="big">\?/.test(unk[4][0]),
    /unknown, agents feed 15 min old/.test(unk[5][0]),
    unk.slice(1).every(([hh, n]) => n === null && /\? belts/.test(hh))].join(","), "true,true,true,true,true,true");
  load(); SNAP.merged_prs = [{ number: 1, key: "FXA-61", title: "a", created: "2026-10-01T00:00:00Z", merged: "2026-10-05T00:00:00Z", merged_by: "pat" },
    { number: 2, key: "FXA-62", title: "<b>b</b>", created: "2026-10-01T00:00:00Z", merged: "2026-10-09T00:00:00Z", merged_by: null }, { number: 3, key: "FXA-63", title: "c", created: "2026-10-02T00:00:00Z", merged: "2026-10-07T00:00:00Z" }];
  const dh2 = String(doneHtml()), keys2 = [...dh2.matchAll(/browse\/(FXA-6\d)/g)].map(m => m[1]).join(",");
  t("done: one table, newest first, no track, the cap and the label in the header", `${(dh2.match(/<table/g) || []).length}|${keys2}|${/class="n /.test(dh2)}|${/3 tickets from the last 30 merged PRs labelled bot-pr/.test(dh2)}|${/<td>pat<\/td>/.test(dh2)}|${/<td>—<\/td>/.test(dh2)}|${/&lt;b&gt;/.test(dh2)}`, "1|FXA-62,FXA-63,FXA-61|false|true|true|true|true");
  SNAP.merged_prs = null; const dn = doneHtml(); SNAP.merged_prs = []; t("done: GitHub failed, and none merged", `${/Could not read merged PRs from GitHub\./.test(dn)}|${/No merged ticket yet\./.test(doneHtml())}`, "true|true");
  [globalThis.SNAP, globalThis.AGENTS, globalThis.STATE, globalThis.TEAM_ADMIN] = s0; }
setTimeout(() => { console.log("FAIL the async checks did not finish"); process.exit(1); }, 10000);
(async () => {
  globalThis.fetch = async url => ({ ok: true, json: async () => url.includes("templates") ? [{ template: "x" }] : [{ id: 7, data: {} }] });
  { const calls = []; globalThis.renderTeams = () => {}; globalThis.loadTeams = async () => {};
    globalThis.teamRecord = async n => ({ name: n, gen: "8", ok: true, rec: { name: n, access: { users: ["U0AAA1111", "U0BBB2222"], channels: [] } }, text: "" });
    // The record editor holds an unsaved edit (status active): Save access must not post it.
    globalThis.TED = { name: "rusty", gen: "7", ok: true, rec: { name: "rusty", status: "draft", access: { users: ["U0AAA1111"], channels: [] }, repos: [] }, text: JSON.stringify({ name: "rusty", status: "active" }) };
    globalThis.SEL = { teams: "rusty" }; globalThis.VIEW = "teams";
    TFORM = { team: "rusty", item: "access", d: { open: false, users: "U0AAA1111\nU0BBB2222", chans: [], other: "" } };
    globalThis.fetch = async (url, o) => { calls.push([url, o?.method || "GET", o?.body]); return { ok: true, status: 200, json: async () => ({ ok: true }) }; };
    const p1 = teamItemSave(), p2 = teamItemSave(); await p1; await p2;
    const posts = calls.filter(c => c[1] === "POST"), body = JSON.parse(posts[0]?.[2] ?? "{}");
    t("settings: Save posts the kept record and generation once, with the people added and the rest kept", `${posts.length}|${body.generation}|${body.record?.access?.users?.join(" ")}|${JSON.stringify(body.record?.repos)}`, "1|7|U0AAA1111 U0BBB2222|[]");
    t("settings: no GET before the POST", calls[0]?.[1], "POST");
    t("settings: unsaved text in the record editor is not posted", body.record?.status, "draft");
    t("settings: a saved item closes its form", TFORM, null);
    globalThis.fetch = async () => ({ ok: false, status: 409, json: async () => ({ error: "stale" }) }); TFORM = { team: "rusty", item: "access", d: { open: false, users: "U0CCC3333", chans: [], other: "" } };
    await teamItemSave(); t("settings: a stale generation says to redo the edit, and keeps the form", `${/Someone changed this team after you loaded it/.test(TFORM?.msg)}|${TFORM?.d.users}`, "true|U0CCC3333");
    calls.length = 0; globalThis.fetch = async (url, o) => { calls.push([url, o?.method || "GET", o?.body]); return { ok: true, status: url.endsWith("/test") && o?.method === "POST" ? 202 : 200, json: async () => ({ ok: true, result: "running" }) }; };
    globalThis.TED = { name: "rusty", gen: "7", ok: true, rec: { name: "rusty", status: "active", repos: [{ slug: "a/b", role: "work" }] } };
    TFORM = { team: "rusty", item: "repos", d: { repos: [{ slug: "a/b", role: "work" }, { slug: "c/d", role: "dep" }] } };
    await teamItemSave(); const sent = JSON.parse(calls.find(c => c[0] === "/api/teams/rusty")?.[2] ?? "{}");
    t("settings: a repo change on an active team saves as draft, then starts a test that activates on a pass", `${sent.record?.status}|${calls.some(c => c[0] === "/api/teams/rusty/test" && c[1] === "POST")}|${TTEST?.activate}`, "draft|true|true");
    clearTimeout(TTEST?.timer); TTEST = null;
    globalThis.document = { getElementById: () => null, querySelector: () => null };
    calls.length = 0; globalThis.NEWT = { name: "relay", repo: "mozilla/fx-private-relay", stack: "", goal: "", errs: {} };
    await teamCreate(); t("new team: a missing stack is marked before any POST", `${NEWT.errs.stack}|${calls.length}`, "Pick a stack.|0");
    NEWT.stack = "none"; globalThis.location = { hash: "" }; const c1 = teamCreate(), c2 = teamCreate(); await c1; await c2;
    t("new team: a double click on Create draft sends one POST, then opens its Settings", `${calls.filter(c => c[0] === "/api/teams" && c[1] === "POST").length}|${location.hash}`, "1|teams/relay/settings"); }
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
    const g = String(routinesGroup(team, 1700000000));
    t("routines: markup in every field renders inert", `${/<img/.test(g)}|${(g.match(/<\/textarea>/g) ?? []).length}`, "false|1");
    t("routines: the prompt textarea holds the text escaped", g.includes(`>${esc(X)}</textarea>`), true);
    t("routines: a run shows its report escaped, folded under Report", /<details data-rt-run="5"><summary>Report<\/summary><pre class="report">&lt;b&gt;x&lt;\/b&gt;<\/pre>/.test(rtHist([{ id: 5, started_at: 1, state: "report", report: "<b>x</b>" }])), true);
    RT.form = null; RT.sel = 5; t("routines: markup in every field renders inert on the routine's page", /<img/.test(String(routinesGroup(team, 1700000000))), false); RT.sel = undefined;
    RT_OPEN.add("5");
    t("sessions: a routine run names its routine and team, escaped, with a link to the team routines",
      String(sessRoutineLink({ routine_run: "7", routine_name: "<b>Code review</b>", profile: "fxa" })), `<a href="#teams/routines/fxa">Routine: &lt;b&gt;Code review&lt;/b&gt; (fxa)</a>`);
    t("sessions: a session that is not a routine run has no routine label", sessRoutine({ key: "agent-x" }), "");
    t("routines: an open report stays open on a repaint", String(rtHist([{ id: 5, started_at: 1, state: "report", report: "x" }])).includes(`<details data-rt-run="5" open>`), true);
    RT_OPEN.clear();
    t("routines: a held report says to read it in History", /held.*History/.test(rtResult({ state: "report", reason: "kept off Slack" }, { channel: "C0123ABCD" })[2]), true);
    t("routines: the report of a routine with no channel is in History", rtResult({ state: "report" }, {})[2], "Report in History");
    t("routines: a failed run with a known reason gets its next step", `${rtFix("the start message did not post in C1: channel_not_found")}|${rtFix("x")}`, "Invite @fxa-agent to the channel, then use Run now.|");
    t("routines: a queued run of a routine with no channel goes to History only", /result goes to History only/.test(rtState({ live: { state: "queued" }, data: {} })), true);
    t("routines: a routine with no channel shows History only for its channel", String(rtDetail({ profile: "fxa" }, { id: 1, version: 1, paused: 0, next: [], data: { name: "x", schedule: "daily 09:00", zone: "UTC", mode: "report" } })).includes("none, History only"), true);
    t("routines: the next run days of a weekly and a weekdays draft", `${rtNextDays({ kind: "weekly", day: "fri", time: "09:00", zone: "UTC" }, 3, Date.UTC(2026, 9, 21, 12)).join(",")}|${rtNextDays({ kind: "weekdays", time: "09:00", zone: "UTC" }, 3, Date.UTC(2026, 9, 23, 10)).join(",")}`,
      "Fri 23 Oct,Fri 30 Oct,Fri 6 Nov|Mon 26 Oct,Tue 27 Oct,Wed 28 Oct");
    t("routines: a start fills the draft: its locked result, and the team's repo only when it has one", `${JSON.stringify(rtFromTpl({ template: "security-review", name: "Security review", mode: "report", locked_mode: "report", prompt: "p" }, [{ slug: "a/b" }]).repos)}|${rtFromTpl({ template: "security-review", mode: "pr", locked_mode: "report" }, [{ slug: "a/b" }, { slug: "c/d" }]).mode}|${rtFromTpl({ template: "code-review" }, [{ slug: "a/b" }, { slug: "c/d" }]).repos.length}`, '["a/b"]|report|0');
    RT.chans = { channels: [{ id: "C0PUB0001", name: "pub", private: false, why: null, why_security: "The channel is public" }, { id: "C0PRI0001", name: "pri", private: true, why: null, why_security: null }] };
    { const sec = String(rtChannelField({ ...rtDraft(), template: "security-review", channel: "C0PRI0001" }, {}, () => "", () => "")), any = String(rtChannelField({ ...rtDraft(), channel: "C0PUB0001" }, {}, () => "", () => ""));
      t("routines: the channel picker: a security review cannot pick a public channel, and a picked channel says the bot is in it",
        `${/value="C0PUB0001" disabled>#pub \(not allowed\)/.test(sec)}|${/okline/.test(sec)}|${/not allowed/.test(any)}|${/okline/.test(any)}`, "true|true|false|true"); }
    t("routines: a channel that is not in the list is a paste field with its ID", /<input id="rt-channel"[^>]*value="C0OTHER01"/.test(String(rtChannelField({ ...rtDraft(), channel: "C0OTHER01" }, {}, () => "", () => ""))), true);
    RT.chans = undefined;
    t("routines: the read-back names the draft, escaped", String(rtReadback({ ...rtDraft(), name: "<b>x</b>", repos: ["a/b"], kind: "daily", time: "10:30", zone: "America/New_York", mode: "pr+notes", max_usd: 5 })),
      "<b>&lt;b&gt;x&lt;/b&gt;</b> runs <b>every day at 10:30 Eastern</b> on <b>a/b</b>, when there are new commits. It opens a draft PR with notes, posts nothing in Slack (the results are in History), and stops at <b>$5.00</b> a run.");
    RTSUM = { teams: {}, routines: { 1: { team: "fxa", template: "code-review", cost_min_30d: 0.4, cost_max_30d: 0.94 }, 2: { team: "fxa", template: "code-review", cost_min_30d: 0.3, cost_max_30d: 0.5 }, 3: { team: "ent", template: "code-review", cost_min_30d: 9, cost_max_30d: 9 } } };
    t("routines: the cost hint is this team's runs of this start", rtCostHint({ profile: "fxa" }, { template: "code-review" }), "code-review runs on this team cost $0.30 to $0.94 a run in the last 30 days.");
    RTSUM = null;
    t("routines: a saved routine with no channel edits and saves with no channel", rtRoutine(rtDraft({ name: "x", schedule: "daily 09:00", zone: "UTC", mode: "report", repos: [] })).channel, "");
    t("routines: the channel field says it is optional", /Slack channel <span class="opt">· optional<\/span>/.test(g) && /results show only in History/.test(g), true);
    t("routines: a queued run promises a free runner, not a minute", /starts when a runner is free, within 60 min/.test(rtState({ live: { state: "queued" }, data: { channel: "C0123ABCD" } })), true);
    t("routines: only a GitHub PR URL is a link", ["javascript:alert(1)", "https://evil.example.com/pull/1", "https://github.com/mozilla/fxa/pull/12"].map(u => /<a class="key"/.test(rtHist([{ id: 1, state: "ok", pr_url: u }]))).join(","), "false,false,true"); }
  { const team = { profile: "fxa", repos: [] }, list = { outerHTML: "old list" }, form = { value: "typed" };
    const el = { querySelector: q => q === "[data-routine-form]" ? form : q === "[data-routine-list]" ? list : null };
    RT = { team: "fxa", list: [{ id: 2, version: 1, paused: 0, tick: Date.now() / 1000, next: [], live: { state: "started", session: "agent-ab12" }, data: { name: "Code review", schedule: "daily 09:00", zone: "UTC", channel: "C0123ABCD", mode: "report" } }],
      form: { d: rtDraft(), dirty: true, errs: {} } };
    t("routines: a poll with a dirty form open repaints nothing under it", `${rtKeepForm(el, team)}|${list.outerHTML}|${form.value}`, "true|old list|typed");
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
    "act:the operator act:the operator wait:the agent, next pass act:the operator wait:the reporter wait:waits on ../x wait:the reporter");
  t("board: a PR that waits on a reviewer feeds only the reviewer line", by("FXA-5").column, "review");
  t("board: a faulted runner and a run with no sandbox are Running with the operator", `${by("FXA-21").fault}|${by("FXA-22").column}|${by("FXA-22").person}`, "true|running|the operator");
  t("board: the tab count is who must act, plus faulted runs; reporter waits are not in it", boardAct(items), 5);
  t("board: every kind has a next step", Object.keys(KIND_LABEL).every(k => classify({ key: "FXA-1", column: "blocked", kind: k }).next.length > 10), true);
  t("board: up next keeps launch order with positions and first queued", `${by("FXA-10").pos}|${by("FXA-11").pos}`, "1|2");
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
    // An old snapshot (no new fields) renders, with only the missing facts unknown.
    const old = { repo: "mozilla/fxa", blocked: [{ key: "FXA-1", summary: "x" }], review: [], inflight: [], queue: { ready: [{ key: "FXA-2" }], skipped: [{ key: "FXA-3", reason: "underspecified: y", last: "2026-10-01T10:00" }] }, health: { lock_held: false } };
    let thrown = ""; try { gl(old); globalThis.TAB = "belts"; beltsHtml(beltGroups()); } catch (e) { thrown = e.message; }
    t("board: an old snapshot renders with no error, blocked in Jira, and an unknown budget", `${thrown}|${boardItems().find(i => i.key === "FXA-1").why}|${/no launch budget/.test(gateLine(now).text)}`, "|blocked in Jira|true"); }
  { const now = Math.round(Date.now() / 1000);
    globalThis.SNAP = { repo: "mozilla/fxa", blocked: null, review: [], inflight: [], queue: { fetch_failed: true, ready: [], skipped: [] } }; globalThis.AGENTS = { runners: [], sessions: [] }; globalThis.VIEW = "pipeline";
    t("belts: a failed Jira read gives no tab count, never 0", tabCount("belts"), "");
    globalThis.SNAP = { repo: "mozilla/fxa", blocked: [], review: [], inflight: [], queue: { ready: [], skipped: [
      { key: "FXA-30", reason: "pick", kind: "needs_decision", last: "2026-10-18T09:00", queued_at: now - 20 * 86400 }, { key: "FXA-31", reason: "pick", kind: "needs_decision", last: "2026-10-18T09:00" }] } };
    const it = boardItems(), a30 = it.find(i => i.key === "FXA-30"), a31 = it.find(i => i.key === "FXA-31");
    t("board: a skipped ticket ages from when it was first queued, not from its last skip", `${boardAge(a30.age)}|${a31.age}`, "20d|null"); }
  { const now = Math.round(Date.now() / 1000);
    globalThis.SNAP = { repo: "mozilla/fxa", blocked: [], review: [], inflight: [], mode: {}, queue: { ready: [1, 2, 3, 4, 5].map(n => ({ key: `FXA-${n}` })), skipped: [] },
      health: { launches_24h: 19, max_launches_per_day: 20, lock_stale_seconds: 1800, next_pass_epoch: now + 300, pass_timer: "on", free_gb: 50, min_free_gb: 20 } };
    globalThis.AGENTS = { launchcap: 3, runners: [], sessions: [] }; globalThis.STATE = { age_seconds: 30, interval: 120, agents_age_seconds: 10, agents_interval: 30 };
    t("gate: 1 launch left in the budget says up to 1", /Up to 1 can launch/.test(gateLine(now).text), true);
    t("gate: no launch left gives no green line", (SNAP.health.launches_24h = 20, gateLine(now).ok), false); }
  t("pipeline: the tabs are Belts, Queue and review, and Done", VIEWS.find(v => v[0] === "pipeline")[3].map(x => x[0]).join(","), "belts,queue,done"); }
JS
rc=$?
# Sandboxes panel (i407 sb-panel): sbDetails() for a session, a pipeline row, a fix row and a routine row as a non-admin.
fns="$(sed -n '/^const esc = /p; /^\/\/ Components:/,/^\/\/ End components\./p; /^const REPO_RE = /p; /^const short = /p; /^const usd = /p; /^const TEAM_RE = /p; /^const rtPr = /p; /^const prHref = /p; /^const sessHref = /p; /^const KEY_RE = /p; /^const LIVE_SESSION = /p; /^const sessTabOf = /p; /^const kvr = /p; /^const closeBtn = /p; /^function sbDetails(/,/^}/p; /^function sbClearGone(/,/^}/p' "$page")"
node - "$fns" <<'JS'
process.argv.splice(1, 1);
eval(process.argv[1].replace(/^(let|const) /gm, "var "));
let fail = 0;
const t = (name, got, want) => { if (got === want) console.log("ok   " + name); else { console.log(`FAIL ${name}: want [${want}] got [${got}]`); fail = 1; } };
const now = 1790000000;
globalThis.AGENTS = { session_max_run_seconds: 14400, sessions: [{ key: "agent-abc123", state: "active" }, { key: "agent-rout01", state: "active" }] }; globalThis.TEAM_ADMIN = { admin: true };
const rows = { live: [
  { id: "sess:agent-abc123", src: "slack", key: "agent-abc123", session: "agent-abc123", title: "<img src=x onerror=alert(1)>", team: "fxa", where: "firecracker", state: "working", started: now - 600, boot_s: "41", pr: "https://github.com/example/repo/pull/41",
    boot_steps: JSON.stringify([{ step: "restoring", s: 3 }, { step: "checking out the commit", s: 30 }, { step: "starting the stack", s: 8 }]), res_peak: JSON.stringify({ load1: 3.2, mem_mb: 4812, disk_pct: 41 }) },
  { id: "pipe:fxa-auto-1", src: "pipeline", key: "FXA-1", slot: "fxa-auto-1", team: "fxa", state: "Agent", started: null, age: 1800, max_seconds: 5400, usd: 1.25 },
  { id: "sess:agent-rout01", src: "routine", key: "agent-rout01", session: "agent-rout01", routine_run: 7, routine_name: "Nightly review", team: "fxa", where: "firecracker", state: "working", started: now - 60, pr: "https://github.com/example/repo/pull/9", res_peak: "{broken" },
  { id: "sess:javascript:alert(1)", src: "slack", key: "javascript:alert(1)", session: "javascript:alert(1)", team: "../x", state: "active", started: now - 60 }],
  fix: [{ id: "fix:agent-def456", src: "slack", key: "agent-def456", fix: { why: "The runner is still up 10 min after its session stopped.", cmd: "fxa-sandbox-ctl stop agent-def456", steps: null } }] };
globalThis.sbRows = () => rows; globalThis.sbTabHas = r => (globalThis.TAB_SRC ?? r.src) === r.src;
const s = sbDetails("sess:agent-abc123", now);
t("panel: a session shows its three boot steps with seconds", (s.match(/<li><span>[^<]+<\/span><b>\d+ s<\/b><\/li>/g) || []).length, 3);
t("panel: boot total and backend", /Boot<\/span><b>41 s · firecracker/.test(s), true);
t("panel: peak load, memory, disk", s.includes("3.2 · 4.7 GB · 41%"), true);
t("panel: a live session links to #sessions/live/<key> and its PR", s.includes('href="#sessions/live/agent-abc123"') && s.includes('href="https://github.com/example/repo/pull/41"'), true);
t("panel: a feed title is escaped", s.includes("&lt;img") && !s.includes("<img src=x"), true);
const p = sbDetails("pipe:fxa-auto-1", now);
t("panel: a pipeline row shows slot, stop, time against the cap, cost and the belt link", ["fxa-auto-1", "Agent", "30m of the 1.5h cap", "$1.25", 'href="#pipeline/belts/FXA-1"', "not recorded for pipeline runs"].every(x => p.includes(x)), true);
const f = sbDetails("fix:agent-def456", now);
t("panel: a fix row shows the list's text and command", f.includes("still up 10 min") && f.includes("<code>fxa-sandbox-ctl stop agent-def456</code>"), true);
TEAM_ADMIN.admin = false; const ra = sbDetails("sess:agent-rout01", now);
t("panel: a routine row gives a non-admin no name and no session, PR or Teams link", !ra.includes("Nightly review") && !/#sessions\/|#teams|github\.com/.test(ra) && ra.includes("Routine · scheduled run"), true);
t("panel: a bad res_peak says not recorded yet, not an error", /Peak load, memory, disk<\/span><b class="na">not recorded yet/.test(ra), true);
TEAM_ADMIN.admin = true; const rb = sbDetails("sess:agent-rout01", now);
t("panel: an admin sees the routine name, the session and its Teams routines link", rb.includes("Routine Nightly review") && rb.includes('href="#sessions/live/agent-rout01"') && rb.includes('href="#teams/routines/fxa"'), true);
const j = sbDetails("sess:javascript:alert(1)", now);
t("panel: a bad session key and team give no link", !/href="#sessions|href="#teams|href="javascript/.test(j), true);
t("panel: an id that is not in the rows gives null", sbDetails("fix:gone", now), null);
rows.stale = true; const fs = sbDetails("fix:agent-def456", now); rows.stale = false;
t("panel: a stale feed shows the fix text and no command", fs.includes("still up 10 min") && !fs.includes("<code>") && fs.includes("feed is stale"), true);
t("panel: the session record gives only the Sessions tab (sessTabOf), never a name, request or output, and the panel never calls sessionDetails", /sessionDetails\(|sx\.|AGENTS\??\.sessions\??\.(?!find)/.test(sbDetails.toString()), false);
const gated = { id: "sess:agent-rout02", src: "routine", key: "agent-rout02", session: "agent-rout02", routine_run: 8, title: "", team: "", where: "firecracker", state: "active", started: now - 60 };
rows.live.push(gated); TEAM_ADMIN.admin = false; const g = sbDetails("sess:agent-rout02", now); TEAM_ADMIN.admin = true;
t("panel: a routine row that arrives gated shows the gated text and no link", g.includes("Routine · scheduled run") && !/href="#/.test(g), true);
const bad = { id: "sess:agent-bad001", src: "slack", key: "agent-bad001", session: "agent-bad001", state: "active", started: now - 60, boot_steps: "{}", res_peak: "5" };
rows.live.push(bad); const b = sbDetails("sess:agent-bad001", now);
t("panel: boot_steps '{}' and res_peak '5' leave the steps out and the panel renders", !b.includes("<ol") && /Peak load, memory, disk<\/span><b class="na">not recorded yet/.test(b), true);
rows.live.push({ ...bad, id: "sess:agent-bad002", boot_steps: "5", res_peak: "{}" });
t("panel: boot_steps '5' and res_peak '{}' too", (x => !x.includes("<ol") && x.includes("not recorded yet") && !x.includes("undefined"))(sbDetails("sess:agent-bad002", now)), true);
sbDetails("fix:agent-def456", now); const fx = rows.fix; rows.fix = [];
rows.err = "the agents read failed"; const u1 = sbDetails("fix:agent-def456", now); delete rows.err;
t("panel: a failed agents read keeps the last panel with the unknown line", u1 != null && u1.includes("feed is unknown") && u1.includes("stop agent-def456"), true);
rows.stale = true; const live0 = rows.live; rows.live = []; const u2 = sbDetails("fix:agent-def456", now); rows.live = live0; rows.stale = false;
t("panel: a stale feed with no rows keeps the panel", u2 != null && u2.includes("feed is unknown"), true);
const ag = AGENTS; AGENTS = null; const u3 = sbDetails("fix:agent-def456", now); AGENTS = ag;
t("panel: before the first agents read a deep link survives", u3 != null, true);
t("panel: a known row list with the row gone gives null", sbDetails("fix:agent-def456", now), null); rows.fix = fx;
{ let hdr = 0; globalThis.renderHeader = () => hdr++; globalThis.SEL = { runners: "x" };
  const el = { contains: () => false, hasAttribute: () => true, setAttribute() {}, focus() {} };
  globalThis.document = { body: { classList: { remove() {} } }, activeElement: null, getElementById: () => el };
  sbClearGone(); t("panel: clearing a selection repaints the header, so #tright's aria-pressed follows", `${hdr}|${SEL.runners}`, "1|undefined"); }
globalThis.TAB_SRC = "pipeline"; t("panel: a row of another tab gives null", sbDetails("fix:agent-def456", now), null);
process.exit(fail);
JS
[ $? = 0 ] || exit 1
# fixCmd() is the only source of a Sandboxes stop command: the old pool and its instFix are gone (i407).
if grep -qE '\b(instFix|renderPool)\b' "$page"; then echo "FAIL the page still has instFix or renderPool"; exit 1; fi
echo "ok   the page has no instFix and no renderPool"
exit "$rc"
