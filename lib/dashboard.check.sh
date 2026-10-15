#!/usr/bin/env bash
# Offline check of the dashboard's session titles: the person's words, not the host's prompt around them.
#   bash lib/dashboard.check.sh
set -u
command -v node >/dev/null || { echo "skip: needs node"; exit 0; }
page="$(dirname "$0")/../dashboard/index.html"
node -e '
eval(process.argv[1].replace(/^let STAT_USD/m, "var STAT_USD"));
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
process.exit(fail);
' "$(sed -n '/^function firstLine(t) {/,/^}/p; /^function sessDay(c) {/,/^}/p; /^let STAT_USD/p; /^function sessUsd(s) {/,/^}/p; /^function rowSpend(from) {/,/^}/p; /^function teamUse() {/,/^}/p; /^function llmWeek(days) {/,/^}/p; /^function sessHeads(ss) {/,/^}/p; /^function chainOf(s, ss) {/,/^}/p' "$page")"
