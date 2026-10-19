#!/usr/bin/env bash
# Offline check of the Sandboxes page's Recently completed table (loadSbDone, renderSbDone): it shows what
# /api/runs/recent?ended=1 sends, in that order, with the tab, the result, the routine gate and a failed read.
#   bash lib/sb-done.check.sh
set -u
command -v node >/dev/null || { echo "skip: needs node"; exit 0; }
page="$(dirname "$0")/../dashboard/index.html"
fns="$(sed -n '/^const esc = /p; /^const usd = /p; /^const ago = /,/;$/p; /^function jiraHref(/p; /^const plainMd = /p; /^const sessHref = /p; /^const teamName = /p; /^const teamLabel = /p; /^const PR_URL_RE = /p; /^function runBadge(r) {/,/^}/p; /^let SB_DONE = /p; /^async function loadSbDone() {/,/^}/p; /^function sbDoneRows() {/,/^}/p; /^function renderSbDone() {/,/^}/p' "$page")"
node - "$fns" <<'JS'
process.argv.splice(1, 1);
let OUT = "";
globalThis.putOv = (id, html) => { OUT = html; return true; };
globalThis.safeRender = fn => fn();
eval(process.argv[1].replace(/^(let|const) /gm, "var "));
let fail = 0;
const t = (name, got, want) => { if (got === want) console.log("ok   " + name); else { console.log(`FAIL ${name}: want [${want}] got [${got}]`); fail = 1; } };
const now = Math.floor(Date.now() / 1000);
globalThis.TEAMS = null; globalThis.SNAP = { team: { jira_site: "https://example.atlassian.net" } }; globalThis.TAB = ""; globalThis.VIEW = "runners";
globalThis.TEAM_ADMIN = { admin: false };
const runs = [
  { src: "slack", key: "agent-sl0001", title: "Why does <img src=x> fail?", team: "fxa", outcome: "answered", end: now - 3600, where: "firecracker", boot_s: 38, mem_mb: 6144, stop: "idle", min: 12, usd: 0.9, routine: false },
  { src: "slack", key: "", title: "Scheduled run", team: "", outcome: "answered", end: now - 7200, where: "gce", stop: "<b>x</b>", min: null, usd: null, routine: true },
  { src: "pipeline", key: "EX-1", title: "Fix the sample", team: "fxa", outcome: "pr", pr_url: "https://github.com/example/repo/pull/41", pr_number: 41, pr_state: "open", end: now - 86400, min: 25, usd: 3.5, routine: false }];
let answer = { runs, error: null }, asked = "";
globalThis.fetch = async u => { asked = String(u); return typeof answer === "number" ? { ok: false, status: answer, json: async () => null } : { ok: true, status: 200, json: async () => answer }; };
(async () => {
  renderSbDone(); t("before the first read: loading", OUT.includes("Loading the recent runs"), true);
  await loadSbDone();
  t("it asks the server for ended runs", asked, "/api/runs/recent?ended=1&limit=100");
  const keys = () => [...OUT.matchAll(/<tr data-sbdone="([^"]*)"/g)].map(m => m[1]).join(",");
  t("the server's order stays: Slack, routine, pipeline", keys(), "agent-sl0001,,EX-1");
  const sl = OUT.split('data-sbdone="agent-sl0001"')[1].split("</tr>")[0];
  t("Slack row: Firecracker, boot, peak memory, stop, session link", /Firecracker.*38 s.*6\.0 GB.*idle/s.test(sl) && sl.includes('href="#sessions/stopped/agent-sl0001"'), true);
  t("feed text is escaped", OUT.includes("&lt;img src=x&gt;") && !OUT.includes("<img src=x>") && OUT.includes("&lt;b&gt;x&lt;/b&gt;"), true);
  t("pipeline row: dash with its title, GCE, the Jira and PR links", /title="not recorded for pipeline runs">—<\/span>/.test(OUT) && /<td>GCE<\/td>/.test(OUT) && OUT.includes('href="https://example.atlassian.net/browse/EX-1"') && OUT.includes('href="https://github.com/example/repo/pull/41"'), true);
  t("a routine run the server gated: no name, no session link", OUT.includes("Routine · scheduled run") && (OUT.match(/#sessions\//g) || []).length === 1, true);
  const rt = OUT.split('data-sbdone=""')[1].split("</tr>")[0];
  t("a gated routine run shows a dash for its team and its cost, not FxA and $0.00", /<td>—<\/td><td>GCE<\/td>/.test(rt) && /<td class="num">—<\/td><td>/.test(rt) && !/\$0\.00|FxA|fxa/.test(rt), true);
  t("the For cell carries the full text in its title", /<td class="sbd-for" title="agent-sl0001 Why does &lt;img src=x&gt; fail\?">/.test(OUT), true);
  globalThis.sbTabHas = r => r.src === "pipeline"; renderSbDone();
  t("Pipeline tab: only the pipeline row", keys(), "EX-1");
  globalThis.sbTabHas = r => r.src === "routine"; globalThis.TEAM_ADMIN = { admin: true }; renderSbDone();
  t("Routines tab (admin): only the routine row", `${(OUT.match(/<tr data-sbdone=/g) || []).length}|${OUT.includes("Routine · scheduled run")}`, "1|true");
  delete globalThis.sbTabHas; globalThis.TEAM_ADMIN = { admin: false }; globalThis.TAB = "routines"; renderSbDone();
  t("non-admin Routines tab: the admin-only text, no rows", OUT.includes("Only a team admin can see routine runs.") && !/data-sbdone/.test(OUT), true);
  globalThis.TAB = "";
  SB_DONE.at = Date.now() - 300000; answer = 503; await loadSbDone();
  t("a failed read keeps the last runs with their age", /may be out of date: HTTP 503\. These rows are from 5m ago/.test(OUT) && keys() === "agent-sl0001,,EX-1", true);
  SB_DONE = null; answer = { runs: [], error: "stats unavailable" }; await loadSbDone();
  t("a failed first read: unknown, no rows", OUT.includes("Recently completed unknown: stats unavailable.") && !/data-sbdone/.test(OUT), true);
  answer = { runs: [], error: null }; await loadSbDone();
  t("empty: No run has ended yet.", OUT.includes("No run has ended yet."), true);
  globalThis.TAB = "pipeline"; await loadSbDone(); t("the Pipeline tab asks the server for pipeline runs, so the limit applies after the filter", asked, "/api/runs/recent?ended=1&limit=100&src=pipeline");
  globalThis.TAB = "routines"; await loadSbDone(); t("the Routines tab asks for routine runs", asked, "/api/runs/recent?ended=1&limit=100&src=routine");
  globalThis.TAB = "";
  globalThis.VIEW = "overview"; asked = ""; await loadSbDone();
  t("no fetch off the Sandboxes page", asked, "");
  process.exit(fail);
})();
JS
