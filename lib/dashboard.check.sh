#!/usr/bin/env bash
# Offline check of the dashboard's helpers: session titles, owners, conversation counts, Slack PR belts, the outcome card.
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
STATS.rows.push({ src: "pipeline", at: "2026-10-14T10:00:00Z", usd: 2 }, { src: "answer", at: "2026-10-15T10:00:00Z", usd: 0.5 });
for (const [from, want] of [[undefined, 12.69], ["2026-10-15", 0.5]]) { const got = Math.round(rowSpend(from) * 100) / 100;
  if (got === want) console.log("ok   spend from every source since " + from); else { console.log(`FAIL spend since ${from}: want [${want}] got [${got}]`); fail = 1; } }
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
process.exit(fail);
' "$(sed -n '/^const esc = /p; /^const days = /p; /^const plainMd = /p; /^const queueWaits = /p; /^function ownerName(s) {/,/^}/p; /^const sessTabOf = /p; /^const sessLink = /p; /^const convTitle = /p; /^const sessSummary = /p; /^function outcomeHtml(s) {/,/^}/p; /^function merged() {/,/^}/p; /^function laneRows() {/,/^}/p; /^function firstLine(t) {/,/^}/p; /^function sessDay(c) {/,/^}/p; /^let STAT_USD/p; /^function sessUsd(s) {/,/^}/p; /^function rowSpend(from) {/,/^}/p; /^function teamUse() {/,/^}/p; /^function llmWeek(days) {/,/^}/p; /^function sessHeads(ss) {/,/^}/p; /^function chainOf(s, ss) {/,/^}/p' "$page")"
