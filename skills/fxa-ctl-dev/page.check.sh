#!/usr/bin/env bash
# page.sh renders the dashboard from the fixture: a probe sees the team heading, and a probe error is printed, not lost.
# It renders dashboard/index.html, so test.sh changed runs it for a change to the page.
#   bash skills/fxa-ctl-dev/page.check.sh
set -u
p="$(dirname "$0")/page.sh"; fail=0
h="$(bash "$p" '#teams/example' --probe 'return document.getElementById("team-h")?.textContent ?? "none"')"; rc=$?
[ "$rc" = 3 ] && { echo "SKIP (no Chrome): the page probes did not run; set CHROME to run them"; exit 0; }
ck() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; fail=1; fi; }
ck "the fixture team page has its heading" "Example" "${h%% *}"
ck "a probe that throws prints its error" "ERR boom" "$(bash "$p" '#teams' --probe 'throw new Error("boom")')"
F="$(dirname "$0")/page-fixture-pipeline.json"
ck "belts at 390 px: no sideways scroll, no stop header, the track below the ticket" "true|none|true" "$(bash "$p" '#pipeline/belts' --fixture "$F" --width 390 --probe '
  const rows = [...document.querySelectorAll(".belt > a")], h = document.querySelector(".bstops");
  const below = rows.every(a => a.querySelector(".trk").getBoundingClientRect().top >= a.querySelector(".tk").getBoundingClientRect().bottom - 1);
  return `${document.documentElement.scrollWidth <= innerWidth && rows.every(a => a.scrollWidth <= a.clientWidth)}|${getComputedStyle(h).display}|${rows.length > 0 && below}`')"
ck "belts at 1280 px: the reason is under the title, and ticket, track and status overlap nothing" "true|true" "$(bash "$p" '#pipeline/belts' --fixture "$F" --width 1280 --probe '
  const a = document.querySelector(".belt[data-belt=\"FXA-1\"] > a"), r = x => a.querySelector(x).getBoundingClientRect(), st = r(".st");
  return `${/approve the tooling change/.test(a.querySelector(".tk .l2").textContent) && r(".tk .l2").top >= r(".tk .t").bottom - 1}|${r(".tk").right <= r(".trk").left && st.left >= r(".trk").right && a.scrollWidth <= a.clientWidth}`')"
ck "a row opens below itself with four blocks and one main action; the right panel is gone" "true|#pipeline/belts|CI: 1 of 22 checks failed;Agent;Review;Agent runs|Open the failing check|/pull/3/checks|none|false" "$(bash "$p" '#pipeline/belts/FXA-3' --fixture "$F" --probe '
  const a = document.querySelector(".belt[data-belt=\"FXA-3\"] > a"), d = a.nextElementSibling, m = d.querySelector(".main");
  return [a.getAttribute("aria-expanded"), a.getAttribute("href"), [...d.querySelectorAll("h3")].map(h => h.textContent.split(":")[0] === "CI" ? h.textContent : h.textContent.split(":")[0]).join(";"), m.textContent, m.getAttribute("href").replace(/^.*\/pull/, "/pull"), getComputedStyle(document.getElementById("right")).display, !!document.getElementById("tright")].join("|")')"
ck "a close keeps the place, focuses the row, and Back leaves the page" "true|0|true|true|true" "$(bash "$p" '#pipeline/belts' --fixture "$F" --width 1280 --probe '
  const w = () => new Promise(r => setTimeout(r, 300)), row = () => document.querySelectorAll(".belt > a")[6], m = document.getElementById("main"), n0 = history.length;
  row().click(); await w(); const open = !!document.querySelector(".bdet"); const top = m.scrollTop; row().click(); await w();
  const closed = !document.querySelector(".bdet") && document.activeElement === row(); row().click(); await w();
  document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true })); await w();
  return [open, history.length - n0, closed, !document.querySelector(".bdet") && document.activeElement === row(), Math.abs(m.scrollTop - top) < 80].join("|")')"
ck "a poll keeps the open row, the Outside group and the focus on the main action" "true|true|true" "$(bash "$p" '#pipeline/belts/FXA-3' --fixture "$F" --probe '
  const w = () => new Promise(r => setTimeout(r, 200));
  document.querySelector("details.bout > summary").click(); await w(); document.querySelector("#bd-FXA-3 .main").focus();
  AGENTS.runners[0].elapsed_seconds += 120; renderLanes(); await w();
  return [document.querySelector("details.bout").open, !!document.getElementById("bd-FXA-3"), document.activeElement?.dataset.focus === "main" && !!document.activeElement.closest("#bd-FXA-3")].join("|")')"
ck "a link to a key with no belt says where it is" "FXA-7 waits on FXA-2 (Queue and review)|FXA-30 is ready in the queue (Queue and review)|FXA-50 merged N ago (Done)|FXA-999 is not on a belt now. Look in Queue and review or Done.|That link names no ticket." "$(for k in FXA-7 FXA-30 FXA-50 FXA-999 '%3Cimg%3E'; do bash "$p" "#pipeline/belts/$k" --fixture "$F" --probe 'return (document.querySelector(".bwhere")?.textContent ?? "none").replace(/merged (today|\d+ days? ago)/, "merged N ago") + (document.querySelector(".bdet") ? " OPEN" : "")'; done | paste -sd'|' -)"
ck "an old Board link lands on Belts, with a Jira key only" "#pipeline/belts/FXA-3|true|#pipeline/belts" "$(bash "$p" '#pipeline/board/FXA-3' --fixture "$F" --probe 'return location.hash + "|" + !!document.getElementById("bd-FXA-3")')|$(bash "$p" '#pipeline/board/%3Cimg%3E' --fixture "$F" --probe 'return location.hash')"
ck "Queue and Done tiles: a merged PR is not stuck, and each row starts with its source" "2,2,1,1|5|1,1,7" "$(bash "$p" '#pipeline/queue' --fixture "$F" --probe 'const b = id => [...document.querySelectorAll(`#${id} .ptiles .big`)].map(e => e.textContent).join(","); return `${b("s-review")}|${document.querySelectorAll("#s-review .qi > .src").length}`')|$(bash "$p" '#pipeline/done' --fixture "$F" --probe 'return [...document.querySelectorAll("#s-done .ptiles .big")].map(e => e.textContent).join(",")')"
ck "shell: the nav rail has no stage-rail margin or width cap, and key 8 (no 8th view) does nothing" "0px|none|#overview|0" "$(bash "$p" '#overview' --fixture "$F" --probe '
  const n = getComputedStyle(document.querySelector("nav.rail")), errs = []; addEventListener("error", e => errs.push(e.message));
  document.body.focus(); document.dispatchEvent(new KeyboardEvent("keydown", { key: "8", bubbles: true })); await new Promise(r => setTimeout(r, 100));
  return [n.marginTop, n.maxWidth, location.hash || "#overview", errs.length].join("|")')"
ck "errors: an empty list says Nothing here, not loading, and a list with errors has no empty group" "Nothing here.|1" "$(bash "$p" '#errors/open' --fixture "$F" --probe '
  AGENTS = null; ERRS = []; renderSide(); const a = document.querySelector(".side .sgroup")?.textContent;
  ERRS = [{ sig: "s1", message: "boom", status: "open" }]; renderSide(); return [a, document.querySelectorAll(".side .slist2 ul").length].join("|")')"
ck "stats: runs and spend a day are SVG charts with one tip a day and no CSS bars; a run with no kind reads not recorded" "true|true|false|true" "$(bash "$p" '#stats/spend' --fixture "$(dirname "$0")/page-fixture-overview.json" --width 1280 --probe '
  await new Promise(r => setTimeout(r, 400)); const n = id => document.querySelectorAll(`#${id} svg.ovchart [data-tip]`).length;
  STATS.rows.push({ at: new Date().toISOString(), src: "pipeline", key: "EX-77", usd: 1 }); LAST["s-stats"] = ""; renderStats();
  return [n("st-runs") >= 28, n("st-spend") === n("st-runs"), !!document.querySelector("#s-stats .bars"), /not recorded/.test(document.getElementById("s-stats").textContent)].join("|")')"
# The whole flow on one fixture, at desktop and phone width: no section fails, nothing scrolls sideways.
flow='const w = () => new Promise(r => setTimeout(r, 250)), bad = () => [...document.querySelectorAll(".emptybox")].some(e => /did not render/.test(e.textContent)), wide = () => document.documentElement.scrollWidth > innerWidth;
  let fails = [];
  const step = (n, ok) => { if (!ok || bad() || wide()) fails.push(n); };
  location.hash = "#pipeline"; await w(); step("open", /Agents working/.test(document.querySelector(".bhead")?.textContent ?? "") && document.querySelectorAll("#s-lanes h2").length === 3);
  document.querySelector(".belt[data-belt=\"FXA-3\"] > a").click(); await w(); step("row open", !!document.getElementById("bd-FXA-3"));
  document.querySelector(".belt[data-belt=\"FXA-3\"] > a").click(); await w(); step("row close", !document.querySelector(".bdet"));
  document.querySelector("details.bout > summary").click(); await w(); step("outside", document.querySelector("details.bout").open);
  location.hash = "#pipeline/done"; await w(); step("done", !!document.querySelector("#s-done table"));
  location.hash = "#pipeline/board/FXA-3"; await w(); await w(); step("board alias", location.hash === "#pipeline/belts/FXA-3");
  return fails.join(",") || "ok"'
ck "the whole Pipeline flow at 1280 px and 390 px" "ok|ok" "$(bash "$p" '#overview' --fixture "$F" --width 1280 --probe "$flow")|$(bash "$p" '#overview' --fixture "$F" --width 390 --probe "$flow")"
ck "a link to an Outside row opens the Outside group and shows the row" "true|true" "$(bash "$p" '#pipeline/belts/agent-abc123' --fixture "$F" --probe 'return document.querySelector("details.bout").open + "|" + document.getElementById("bd-agent-abc123").checkVisibility()')"
ck "Watch the agent opens the terminal, moves the focus there, and a poll keeps it open" "true|true|true" "$(bash "$p" '#pipeline/belts/FXA-20' --fixture "$F" --probe '
  const w = () => new Promise(r => setTimeout(r, 200)); document.querySelector("#bd-FXA-20 .main").click(); await w();
  const d = () => document.getElementById("lane-term-FXA-20"), o = d().open, f = !!document.activeElement?.closest("#lane-term-FXA-20");
  renderLanes(); await w(); return [o, f, d().open].join("|")')"
# Sandboxes (i407 sb-list-fixes): one list on the Overview floor rows, fix rows with a safe command, the badge.
B="$(dirname "$0")/page-fixture-sandboxes.json"
sbw='const w = () => new Promise(r => setTimeout(r, 300)); await w(); const L = () => document.getElementById("sb-list"), N = () => document.getElementById("n-runners");
  const codes = () => [...L().querySelectorAll("code")].map(c => c.textContent), inBtn = () => [...L().querySelectorAll("button code, button .steps")].length;'
ck "Sandboxes: live rows then 'Needs a fix · 3', commands in <code> outside the buttons, the badge" "true|EX-101,EX-102,agent-ex0001,Nightly review,agent-ex0003|Needs a fix · 3|fxa-sandbox-ctl stop agent-ex0004;fxa-sandbox-ctl stop agent-41c0e6|0|true|3|3 sandboxes need a fix|true" "$(bash "$p" '#runners' --fixture "$B" --width 1280 --probe "$sbw"'
  render(); const live = [...L().querySelectorAll(".sbl")[0].querySelectorAll("button")].map(b => b.textContent.replace(/^(Pipeline|Slack) /, ""));
  return [sbRows().live[0].max_seconds === 5400 && sbRows().live[0].usd === 1.25, live.join(","), L().querySelector("h3.sbh").textContent, codes().join(";"), inBtn(), /ex-auto-4 is not free for a launch\. Its last ticket EX-130 is not in flight/.test(L().textContent) && /fxa-sandbox-ctl slots/.test(L().textContent),
    N().textContent, N().getAttribute("aria-label"), /ex-auto-3 · held for a run in flight: ex-auto-5 \(EX-103\) · 2 session slots/.test(L().textContent)].join("|")')"
ck "Sandboxes as a non-admin: no routine name, no routine link, the Routines tab says why" "false|true|false|Only a team admin can see routine runs." "$(bash "$p" '#runners' --fixture "$B" --width 1280 --probe "$sbw"'
  TEAM_ADMIN = { admin: false }; render(); const t = L().innerHTML;
  const r = [/Nightly review/.test(t), /Routine · scheduled run/.test(t), /href=/.test(t)];
  location.hash = "#runners/routines"; await w(); return [...r, L().textContent.trim()].join("|")')"
ck "Sandboxes: feed text never becomes markup, and a command shows only for a safe name" "true|false|true|false" "$(bash "$p" '#runners' --fixture "$B" --width 1280 --probe "$sbw"'
  AGENTS.instances.push({ name: "agent-x;rm -rf ~", state: "terminated", age_seconds: 9000, where: "gce" }); AGENTS.sessions[0].request = "<img src=x onerror=alert(1)>"; render();
  const t = L().innerHTML; return [/&lt;img/.test(t), /<img src=x/.test(t), /agent-x;rm -rf ~/.test(L().textContent), codes().some(c => /rm -rf/.test(c))].join("|")')"
ck "Sandboxes review: an instance on its way up or down (provisioning, staging, stopping) behind a live or stopped session or a card gets no command and no badge count" "starting|stopping|starting|0|2|true" "$(bash "$p" '#runners' --fixture "$B" --width 1280 --probe "$sbw"'
  const set = (n, s) => { AGENTS.instances.find(v => v.name === n).state = s; };
  AGENTS.instances.push({ name: "agent-agent-ex0001", state: "provisioning", age_seconds: 400, where: "gce" }); set("agent-agent-ex0004", "stopping"); set("agent-ex-101", "staging");
  render(); const r = sbRows(), row = id => r.live.find(x => x.id === id)?.state;
  return [row("sess:agent-ex0001"), row("sess:agent-ex0004"), r.live.find(x => x.key === "EX-101")?.state, codes().filter(c => /ex0001|ex0004|ex-101/.test(c)).length, r.fix.length,
    !r.unknown.some(u => /ex0001|ex0004|ex-101/.test(u.slot))].join("|")')"
ck "Sandboxes: a stopped session whose runner is left is a fix row after 5 min; without runner_left it waits the 10 min grace" "stopping|fix|stopping" "$(bash "$p" '#runners' --fixture "$B" --width 1280 --probe "$sbw"'
  const s = AGENTS.sessions.find(x => x.key === "agent-ex0004"), at = ago => { s.stopped_at = Math.floor(Date.now() / 1000) - ago; render(); const r = sbRows();
    return r.fix.some(x => x.id === "fix:agent-agent-ex0004") ? "fix" : r.live.find(x => x.id === "sess:agent-ex0004")?.state; };
  const a = at(120), b = at(360); delete s.runner_left; return [a, b, at(360)].join("|")')"
ck "Sandboxes review: a stopped session with an unsafe key gets no command, and nothing says 'stop null'" "false|false" "$(bash "$p" '#runners' --fixture "$B" --width 1280 --probe "$sbw"'
  AGENTS.sessions[3].key = "x;rm -rf ~"; AGENTS.instances.push({ name: "agent-x;rm -rf ~", state: "running", age_seconds: 9000, where: "gce" }); render();
  return [codes().some(c => /rm -rf/.test(c)), /stop null/.test(L().textContent)].join("|")')"
ck "Sandboxes review: a non-admin sees no request, routine name or cost of a stopped routine session with a runner left" "true|false|false|false" "$(bash "$p" '#runners' --fixture "$B" --width 1280 --probe "$sbw"'
  Object.assign(AGENTS.sessions[3], { routine_run: 7, routine_name: "Secret weekly", cost: 9.87, summary: JSON.stringify({ cost: 9.87 }) }); TEAM_ADMIN = { admin: false }; render(); const t = L().textContent;
  return [/Routine · scheduled run/.test(t), /another sample question/.test(t), /Secret weekly/.test(t), /9\.87/.test(t)].join("|")')"
ck "Sandboxes review: a failed session with no stopped_at whose runner is up is a fix row at once, with the badge" "true|true|4" "$(bash "$p" '#runners' --fixture "$B" --width 1280 --probe "$sbw"'
  AGENTS.sessions.push({ key: "agent-fl1", state: "failed", created: Date.now() / 1000 - 900, profile: "fxa" }); AGENTS.instances.push({ name: "agent-agent-fl1", state: "running", age_seconds: 900, where: "gce" }); render();
  return [sbRows().fix.some(r => r.id === "fix:agent-agent-fl1"), codes().includes("fxa-sandbox-ctl stop agent-fl1"), N().textContent].join("|")')"
ck "Sandboxes review: the panel of a real live row ('working') opens the session on the Live tab, from the session record" "working|#sessions/live/agent-ex0001" "$(bash "$p" '#runners' --fixture "$B" --width 1280 --probe "$sbw"'
  const id = "sess:agent-ex0001", h = document.createElement("div"); h.innerHTML = sbDetails(id) || "";
  return [sbRows().live.find(x => x.id === id)?.state, [...h.querySelectorAll("a")].map(a => a.getAttribute("href")).find(x => /^#sessions\//.test(x || ""))].join("|")')"
ck "Sandboxes: a normal stop is 'stopping' with no command; 10 min later it is a fix row" "stopping|false|true|4" "$(bash "$p" '#runners' --fixture "$B" --width 1280 --probe "$sbw"'
  const st = () => [...L().querySelectorAll("tbody tr")].find(li => li.querySelector("[data-sbsel=\"sess:agent-ex0003\"], [data-sbsel=\"fix:agent-agent-ex0003\"]"));
  const a = st().querySelector("td:nth-child(3)")?.textContent, b = codes().includes("fxa-sandbox-ctl stop agent-ex0003");
  AGENTS.sessions[2].stopped_at = Date.now() / 1000 - 700; render();
  return [a, b, codes().includes("fxa-sandbox-ctl stop agent-ex0003"), N().textContent].join("|")')"
ck "Sandboxes: a stale feed shows the rows with a warning, no command, and badge '?'" "true|0|?|Sandbox fixes unknown: the agents feed could not be read" "$(bash "$p" '#runners' --fixture "$B" --width 1280 --probe "$sbw"'
  STATE.agents_age_seconds = 600; render(); return [/The agents feed is 10 min old: these rows may be out of date\./.test(L().textContent), codes().length, N().textContent, N().getAttribute("aria-label")].join("|")')"
ck "Sandboxes: a held slot names a ticket only when it is one, and an old snapshot is not checked yet" "true|true|?|false" "$(bash "$p" '#runners' --fixture "$B" --width 1280 --probe "$sbw"'
  AGENTS.pool[3] = { ...AGENTS.pool[3], key: "HEAD", branch: "HEAD" }; render(); const a = /ex-auto-4 is not free for a launch \(branch HEAD\)/.test(L().textContent);
  AGENTS.pool[3] = { ...AGENTS.pool[3], key: "EX-130", branch: "ex-130" }; SNAP.generated_at = new Date(Date.parse(AGENTS.generated_at) - 9999e3).toISOString(); render();
  return [a, /ex-auto-4 held by EX-130 · in flight not checked yet/.test(L().textContent), N().textContent, /Its last ticket EX-130/.test(L().textContent)].join("|")')"
ck "Sandboxes: the tabs filter the list" "EX-101,EX-102,agent-agent-41c0e6,EX-130|agent-ex0001,agent-ex0003,agent-ex0004|Nightly review" "$(bash "$p" '#runners/pipeline' --fixture "$B" --width 1280 --probe "$sbw"'
  render(); const keys = () => [...L().querySelectorAll("[data-sbsel]")].map(b => b.textContent.replace(/^(Pipeline|Slack) /, "")).join(",");
  const a = keys(); location.hash = "#runners/slack"; await w(); const b = keys(); location.hash = "#runners/routines"; await w(); return [a, b, keys()].join("|")')"
ck "Sandboxes: nothing runs; nothing set up; the feed failed" "No sandbox runs now.|true|No sandbox slot is set up, and no Slack session is live.|Sandboxes unknown: the agents feed could not be read.|?" "$(bash "$p" '#runners' --fixture "$B" --width 1280 --probe "$sbw"'
  AGENTS.runners = []; AGENTS.sessions = []; AGENTS.instances = []; AGENTS.pool = AGENTS.pool.map(x => ({ ...x, agent: null, busy: false, key: null })); AGENTS.free_slots = AGENTS.pool.map(x => x.slot); render();
  const a = [L().querySelector(".emptybox")?.textContent, N().textContent === "" && !N().hasAttribute("aria-label")];
  AGENTS.pool = []; AGENTS.free_slots = []; render(); const b = L().querySelector(".emptybox")?.textContent;
  STATE.agents_error = "boom"; render(); return [...a, b, L().textContent.trim(), N().textContent].join("|")')"
ck "Sandboxes: one part that throws leaves the cards and the badge" "true|true|3" "$(bash "$p" '#runners' --fixture "$B" --width 1280 --probe "$sbw"'
  renderSbList = () => { throw new Error("boom"); }; render(); return [/This section did not render: boom\./.test(L().textContent), !!document.querySelector("#sb-cards .stat, #sb-cards .card"), N().textContent].join("|")')"
ck "Sandboxes recheck: a stale feed keeps its rows but no 'No sandbox runs now.' and no free line; a stray on a slot's agent is unknown; a failed slot read; a null SNAP keeps the list" "true|false|false|true|true|false|true" "$(bash "$p" '#runners' --fixture "$B" --width 1280 --probe "$sbw"'
  STATE.agents_age_seconds = 600; render(); const st = [L().querySelectorAll(".sbl tbody tr").length > 0, /No sandbox runs now/.test(L().textContent), !!L().querySelector(".sbfree")];
  STATE.agents_age_seconds = 12; AGENTS.instances.push({ name: "agent-ex-109", state: "running", age_seconds: 900, where: "gce" }); AGENTS.pool[2] = { ...AGENTS.pool[2], agent: "ex-109", busy: true }; render();
  const u = /agent-ex-109: the slot says it runs, but the agents feed has no run row/.test(L().textContent) && !codes().includes("fxa-sandbox-ctl stop ex-109");
  AGENTS.free_slots = null; render(); const sl = /ex-auto-4: slots unknown: the slot read failed/.test(L().textContent) && !/Its last ticket EX-130/.test(L().textContent);
  AGENTS.free_slots = ["ex-auto-3"]; AGENTS.pool[2] = { ...AGENTS.pool[2], agent: null, busy: false }; AGENTS.instances.pop(); SNAP = null; render();
  return [...st, u, sl, /\/home|\/Users|worktree path/.test(L().textContent), L().querySelectorAll(".sbl tbody tr").length > 0].join("|")')"
ck "Sandboxes at 390 and 1280 px: no sideways scroll, no side list" "true|true|true" "$(bash "$p" '#runners' --fixture "$B" --width 390 --probe "$sbw"'render(); return document.documentElement.scrollWidth <= innerWidth')|$(bash "$p" '#runners' --fixture "$B" --width 1280 --probe "$sbw"'render(); return document.documentElement.scrollWidth <= innerWidth')|$(bash "$p" '#runners' --fixture "$B" --width 1280 --probe "$sbw"'const s = getComputedStyle(document.getElementById("side")); return s.visibility === "hidden" || s.display === "none"')"
ck "Sessions: a failed boot, now stopped with reason 'boot failed', still reads boot failed in red; a person's stop reads stopped" "boot failed|bad|stopped" \
  "$(bash "$p" '#sessions' --fixture "$F" --probe 'const a = sessStatus({ state: "stopped", stop_reason: "boot failed" }); return [a[0], a[1], sessStatus({ state: "stopped", stop_reason: "owner" })[0]].join("|")')"
ck "Pipeline tab counts: a failed feed reads '?', never a confident number" "?|?" \
  "$(bash "$p" '#pipeline/belts' --fixture "$F" --probe 'SNAP.review = null; SNAP.open_prs = null; const a = tabCount("belts"); SNAP.queue = { ...(SNAP.queue || {}), fetch_failed: true, ready: [] }; return [a, tabCount("queue")].join("|")')"
# Stats day lists are tables with a day and figures, the newest day first, with no sideways scroll at 390 px.
SF="$(dirname "$0")/page-fixture-stats.json"
st='const m = document.getElementById("main"), t = [...m.querySelectorAll(".tscroll table")]; return [m.innerText.includes("did not render"), t.map(x => x.querySelectorAll("tbody tr").length).join(","), t[0]?.querySelector("tbody td")?.textContent === new Date().toLocaleDateString(undefined, { month: "short", day: "numeric" }), document.documentElement.scrollWidth <= innerWidth].join("|")'
ck "Stats: Runners and LLM and Pipeline show their days as tables" "false|3,3|true|true|false|2|true|true" "$(bash "$p" '#stats/runners' --fixture "$SF" --width 390 --probe "$st")|$(bash "$p" '#stats/pipeline' --fixture "$SF" --width 1280 --probe "$st")"
# #attn sandbox alerts (i376): runner faults with one stop rule, and feed text that never becomes markup.
ck "#attn: wrong base with its stop, goal rejected with its next step, idle warn, strays by the stop rule, escaped" "true|true|true|true|true|true|true|true" "$(bash "$p" '#overview' --fixture "$F" --width 1280 --probe '
  const x = "<img src=x onerror=alert(1)>";
  SNAP.inflight = [{ key: "FXA-41", summary: x }, { key: "FXA-42", summary: "g" }, { key: "FXA-45", summary: "i" }, { key: "FXA-46", summary: "n" }];
  AGENTS.runners = [{ key: "FXA-41", name: "fxa-auto-1", base_ok: false, agent_alive: true, stage: "watching", agent: {} },
    { key: "FXA-42", name: "fxa-auto-2", agent_alive: true, stage: "watching", agent: { num_turns: 0 } },
    { key: "FXA-45", name: "fxa-auto-5", agent_alive: true, stage: "watching", agent: { idle_seconds: 900, last_tool: x } },
    { key: "FXA-46", name: "x;rm -rf", base_ok: false, agent_alive: true, stage: "watching", agent: {} }];
  AGENTS.sessions = []; AGENTS.instances = [{ name: "agent-fxa-auto-9", state: "running", age_seconds: 600 }, { name: "agent-x;id", state: "running", age_seconds: 600 },
    { name: "gke-pool-1", state: "running", age_seconds: 600 }];
  renderAlerts(); const a = document.getElementById("attn"), h = a.innerHTML, row = k => [...a.querySelectorAll(".alert")].find(e => e.textContent.includes(k));
  return [/fxa-sandbox-ctl stop fxa-auto-1/.test(row("FXA-41")?.textContent), /shorten the ticket and requeue/.test(row("FXA-42")?.textContent),
    row("FXA-45")?.classList.contains("warn"), !!row("FXA-46") && !/fxa-sandbox-ctl stop/.test(row("FXA-46").textContent), /stop fxa-auto-9/.test(row("agent-fxa-auto-9")?.textContent),
    !!row("agent-x;id") && !!row("gke-pool-1") && !/stop/.test(row("agent-x;id").textContent + row("gke-pool-1").textContent),
    row("FXA-41").textContent.includes("<img src=x") && row("FXA-45").textContent.includes("<img src=x"), !a.querySelector("img")].join("|")')"
# Needs you (i378, i379): one number on the card, the rail badge and the tab title; a stray adds a sandbox
# part that moves the focus to #attn; a stale agents feed makes it unknown, never 0.
ck "Needs you: card, badge and title agree; a stray adds a sandbox part that focuses #attn; a stale feed gives ?" "true|true|true|1 sandbox alert|attn|?|true" "$(bash "$p" '#overview' --fixture "$F" --width 1280 --probe '
  const big = () => document.querySelector("#ov-needs .big").textContent, b = beltGroups().needs.length;
  const r1 = [big() === String(b), document.getElementById("n-overview").textContent === (b ? String(b) : document.querySelectorAll("#attn .alert").length ? "!" : ""), document.title.startsWith(b ? `(${b}) ` : "")];
  AGENTS.instances = [...(AGENTS.instances ?? []), { name: "agent-zz9", state: "running", age_seconds: 300 }]; render();
  const sb = [...document.querySelectorAll("#ov-needs .sub a")].find(a => a.hasAttribute("data-attn")); sb?.click();
  const r2 = [sb?.textContent, document.activeElement?.id];
  STATE.agents_age_seconds = 1200; STATE.agents_interval = 30; render();
  return [...r1, ...r2, big(), /unknown, agents feed/.test(document.querySelector("#ov-needs .sub").textContent)].join("|")')"
# The Merged and Cost cards (i380): the cost is the Stats PRs number; an unread or old PR list shows no 0;
# the focus stays on a card link across a poll; a renderer that throws does not stop the others.
ck "Merged and Cost: Stats number, no 0 for an unread or old list, focus kept, a throw stops nothing" "2|\$1.50|—|true|true|true" "$(bash "$p" '#overview' --fixture "$F" --width 1280 --probe '
  const now = Date.now(), iso = d => new Date(now - d * 86400000).toISOString(), lk = k => document.querySelector(`#ov-main [data-focus="${k}"]`);
  STATS = { prs: [{ n: 1, merged: iso(1) }, { n: 2, merged: iso(2) }, { n: 3, merged: iso(20) }], prs_at: Math.round(now / 1000) - 60, rows: [{ at: iso(1), usd: 2 }, { at: iso(3), usd: 1 }, { at: iso(30), usd: 50 }] };
  OV_METRIC = "merged"; renderOvMain(); const m = lk("ovm-open-merged").querySelector(".big").textContent, c = lk("ovm-open-cost").querySelector(".big").textContent;
  const same = c === usd(costPerMerged(now - 7 * 86400000, now, STATS.prs, STATS.rows).per);
  // A value outside the links changes, so the card is rewritten: the focus must come back to the same link.
  lk("ovm-open-cost").focus(); const n0 = lk("ovm-open-cost"); STATS = { ...STATS, rows: [...STATS.rows, { at: iso(0.1), usd: 4 }] }; render();
  const kept = document.activeElement?.dataset.focus === "ovm-open-cost" && document.activeElement !== n0 && /\$3\.50/.test(lk("ovm-open-cost").textContent);
  STATS = { ...STATS, prs: null }; renderOvMain(); const none = document.querySelector("#ov-main [data-ovmetric=\"merged\"] .mv").textContent;
  STATS = { ...STATS, prs: [], prs_at: Math.round(now / 1000) - 7200 }; renderOvMain(); const old = /old/.test(document.getElementById("ov-main").textContent) && !lk("ovm-open-cost");
  const nav = renderNav; renderNav = () => { throw new Error("boom"); }; document.title = "x"; render(); renderNav = nav;
  return [m, c, none, same && kept, old, document.title !== "x"].join("|")')"
ck "Stats PRs renders with a PR merged this week and a run in it" "true|false" "$(bash "$p" '#stats/prs' --fixture "$F" --width 1280 --probe '
  const now = Date.now(), iso = d => new Date(now - d * 86400000).toISOString();
  STATS = { ...(STATS ?? {}), prs: [{ n: 1, key: "FXA-1", title: "t", state: "MERGED", created: iso(2), merged: iso(1), add: 1, del: 0, src: "pipeline" }], rows: [{ at: iso(1), usd: 2, src: "pipeline", key: "FXA-1" }], llm: STATS?.llm ?? {} };
  renderStats(); const t = document.body.innerText; return [/Cost per merged PR/i.test(t), /did not render|is not defined/.test(t)].join("|")')"
# Merged in the range counts every PR that merged in it, and the merged lists show the same PRs: one opened 10 days ago
# and merged yesterday is in the count, Recently merged and Merged by; one opened today and still open is not.
ck "Stats PRs on 7 days: Merged, Recently merged and Merged by agree, with a PR opened before the range" "2|2|2|1" "$(bash "$p" '#stats/prs' --fixture "$F" --width 1280 --probe '
  const now = Date.now(), iso = d => new Date(now - d * 86400000).toISOString(); SF = { ...SF_DEFAULT, range: "7d" };
  STATS = { ...(STATS ?? {}), llm: STATS?.llm ?? {}, rows: [{ at: iso(1), usd: 2, src: "pipeline", key: "FXA-1" }], prs: [
    { n: 1, key: "FXA-1", title: "a", state: "MERGED", created: iso(10), merged: iso(1), add: 1, del: 0, src: "pipeline", by: "x" },
    { n: 2, key: "FXA-2", title: "b", state: "MERGED", created: iso(3), merged: iso(2), add: 1, del: 0, src: "pipeline", by: "x" },
    { n: 3, key: "FXA-3", title: "c", state: "OPEN", created: iso(0.1), add: 1, del: 0, src: "pipeline" }] };
  renderStats(); const card = t => [...document.querySelectorAll("#s-stats .chart")].find(c => c.querySelector("h2")?.textContent.startsWith(t));
  const big = [...document.querySelectorAll("#s-stats .kpis > *")].find(k => /^Merged/.test(k.textContent)).textContent.match(/\d+/)[0];
  return [big, card("Recently merged").querySelectorAll(".kv").length, [...card("By source").querySelectorAll(".kv")].pop().querySelector("b").textContent, card("Still open").querySelectorAll(".kv").length].join("|")')"
# Spend (ov-main, the Spend tab). Rows over 100 days in four sources, one 95 days ago; a peak day with 3 merged PRs.
SP='const DAY = 86400000, noon = d => { const t = new Date(); t.setHours(12, 0, 0, 0); return new Date(t.getTime() - d * DAY).toISOString(); };
  const rows = []; for (let d = 0; d < 100; d++) [["pipeline", 1], ["pass", 0.5], ["slack", 0.25], ["answer", 0.125]].forEach(([src, u]) => rows.push({ at: noon(d), src, usd: d === 4 ? u * 20 : u, key: `K-${d}-${src}`, model: "claude-opus-5-5" }));
  rows.push({ at: noon(95), src: "pipeline", usd: 1000, key: "OLD-1" });
  STATS = { rows, prs: [1, 2, 3].map(n => ({ n, merged: noon(4), src: "pipeline" })), prs_at: Math.round(Date.now() / 1000) - 60, llm: { hour_usd: 0.42 } }; STATS_ERR = null;
  const statsSpend = r => { SF = { ...SF_DEFAULT, range: r }; STATS_TAB = "spend"; LAST["s-stats"] = ""; renderStats(); return [...document.querySelectorAll("#s-stats .stat")].find(c => c.querySelector(".lbl").textContent === "Spend").querySelector(".big").textContent; };'
ck "Spend: equals Stats for 7, 30 and 90 days; sources add up; the 95-day row is out of 90d; the peak names 3 merged PRs" "true|true|true|true" "$(bash "$p" '#overview' --fixture "$F" --width 1280 --probe "$SP"'
  const eq = ["7d", "30d", "90d"].every(r => usd(ovSpend(r).total) === statsSpend(r));
  const sp = ovSpend("90d"), parts = Object.values(sp.by).reduce((a, b) => a + b, 0);
  OV_RANGE = "30d"; OV_METRIC = "spend"; renderOvMain(); const t = document.querySelector("#ov-main").textContent;
  return [eq, Math.abs(parts - sp.total) < 1e-9, sp.total < 1000, /3 PRs merged that day/.test(t)].join("|")')"
# A source whose log starts inside the period before gives no change; the average a day counts only the days since the log starts.
ck "Spend and Runs: a source whose first row is 40 days ago gives no 30-day change text, the full log keeps it; 90-day average from the first row" "true|true|true" "$(bash "$p" '#overview' --fixture "$F" --width 1280 --probe "$SP"'
  const chg = () => { OV_RANGE = "30d"; renderOvMain(); return ["spend", "runs"].map(k => document.querySelector(`#ov-main [data-ovmetric="${k}"] .chg`)?.textContent ?? ""); };
  const kept = chg().every(t => /%/.test(t));
  STATS.rows.push(...[40, 5].map(d => ({ at: noon(d), src: "answer2", usd: 1, key: "NEW-" + d }))); const none = chg().every(t => t === "");
  STATS.rows = STATS.rows.filter(r => Date.parse(r.at) > Date.now() - 20 * DAY); const sp = ovSpend("90d");
  return [kept, none, Math.abs(sp.perDay - sp.total / sp.days.filter(d => d.t >= localDay(Date.now() - 19.5 * DAY)).length) < 1e-9].join("|")')"
ck "A failed stats read: the cards say so, show no \$0.00, keep the last figures; a throwing card leaves the others" "true|true|true" "$(bash "$p" '#overview' --fixture "$F" --width 1280 --probe "$SP"'
  const w = () => new Promise(r => setTimeout(r, 50)), f0 = window.fetch, txt = id => document.getElementById(id).textContent;
  STATS = null; window.fetch = async u => String(u).includes("/api/stats") ? new Response("not json", { status: 502 }) : f0(u); STATS_AT = 0; await loadStats(); await w();
  const a = /could not be read/.test(txt("ov-main")) && !/\$0\.00/.test(txt("ov-main") + txt("ov-llm") + txt("ov-budget"));
  window.fetch = f0; { '"$SP"' } const keep = STATS; STATS_AT = 0; window.fetch = async u => String(u).includes("/api/stats") ? new Response("{}", { status: 500 }) : f0(u); await loadStats(); window.fetch = f0;
  const b = STATS === keep && /These figures are from/.test(txt("ov-main"));
  const mn = renderOvMain; renderOvMain = () => { throw new Error("boom"); }; STATS_ERR = null; STATS_AT = 0; window.fetch = async u => String(u).includes("/api/stats") ? new Response(JSON.stringify(keep)) : f0(u);
  await loadStats(); window.fetch = f0; renderOvMain = mn;
  return [a, b, /did not render: boom/.test(txt("ov-main")) && /LLM spend/.test(txt("ov-llm"))].join("|")')"
ck "A spend link sets Stats for the visit: totals agree, no Stats click saves, a bad value does nothing, Restore and Keep these" "true|true|true|true|true" "$(bash "$p" '#overview' --fixture "$F" --width 1280 --probe "$SP"'
  const w = () => new Promise(r => setTimeout(r, 100)); localStorage.setItem("statsFilter", JSON.stringify({ ...SF_DEFAULT, model: "m1" })); SF = { ...SF_DEFAULT, model: "m1" }; SF_FROM_OV = false;
  OV_RANGE = "7d"; OV_METRIC = "spend"; renderOvMain(); const lk = document.querySelector("#ov-main [data-focus=\"ovm-open-spend\"]"), tot = lk.querySelector(".big").textContent; lk.click(); await w();
  const a = location.hash === "#stats/spend" && SF.range === "7d" && SF.model === "all" && statsSpend("7d") === tot && !!document.querySelector("#s-stats .sfov");
  SF_FROM_OV = true; setStatsFilter({ range: "30d" }); const b = JSON.parse(localStorage.getItem("statsFilter")).model === "m1";
  const x = document.createElement("a"); x.dataset.sfrange = "x;y"; document.body.appendChild(x); const before = SF.range; x.click(); const c = SF.range === before;
  document.querySelector("[data-sfrestore]").click(); const d = SF.model === "m1" && !SF_FROM_OV;
  SF_FROM_OV = true; setStatsFilter({ range: "90d" }, false); document.querySelector("[data-sfkeep]").click(); const e = JSON.parse(localStorage.getItem("statsFilter")).range === "90d" && !SF_FROM_OV;
  return [a, b, c, d, e].join("|")')"
# Daylight saving (New York): with a fixed date after each change, Spend still equals Stats and the chart has one column for each day of the range.
DST='const FIX = __T__, R = Date; class D extends R { constructor(...a) { super(...(a.length ? a : [FIX])); } static now() { return FIX; } } window.Date = D;
  const DAY = 86400000, rows = []; for (let i = 0; i < 100; i++) { const d = new R(FIX); d.setDate(d.getDate() - i); d.setHours(12, 0, 0, 0); rows.push({ at: d.toISOString(), src: "pipeline", usd: 1, key: "K" + i }); }
  STATS = { rows, prs: [], prs_at: null, llm: {} }; STATS_ERR = null;
  const statsSpend = r => { SF = { ...SF_DEFAULT, range: r }; STATS_TAB = "spend"; LAST["s-stats"] = ""; renderStats(); return [...document.querySelectorAll("#s-stats .stat")].find(c => c.querySelector(".lbl").textContent === "Spend").querySelector(".big").textContent; };
  const eq = ["7d", "30d", "90d"].every(r => usd(ovSpend(r).total) === statsSpend(r)); OV_RANGE = "30d"; OV_METRIC = "spend"; renderOvMain();
  const n = [[7, "7d"], [30, "30d"], [90, "90d"]].every(([k, r]) => ovSpend(r).days.length === k && new R(statsBounds(r)[0]).getHours() === 0);
  return [eq, document.querySelectorAll("#ov-main .ovchart .hit").length === ovSpend("30d").days.length, n].join("|")'
for t in 'new Date(2027, 2, 20, 12).getTime()' 'new Date(2027, 2, 16, 12).getTime()' 'new Date(2026, 10, 3, 12).getTime()'; do
  ck "daylight saving: Spend equals Stats, the chart has one column for each day, and 7d/30d/90d start at local midnight with n days ($t)" "true|true|true" "$(TZ=America/New_York bash "$p" '#overview' --fixture "$F" --width 1280 --probe "${DST/__T__/$t}")"
done
# Overview charts are drawn at the card width: the axis text keeps --t-tiny, and a hidden list gives each point in words.
OVC="$SP"'
  STATS.rows.push({ at: new Date(Date.now() - 3600000).toISOString(), src: "pipeline", usd: 1, key: "H-1" });
  STATS.llm.days = [3, 2, 1].map(d => ({ day: new Date(Date.now() - d * DAY).toLocaleDateString("en-CA"), usd: d }));
  OV_RANGE = "30d"; OV_METRIC = "spend"; [renderOvMain, renderOvBudget, renderOvLlm, renderOvHours].forEach(f => f());
  const sp = document.createElement("span"); sp.style.font = "var(--t-tiny) var(--sans)"; sp.textContent = "$0"; document.body.append(sp); const lh = sp.getBoundingClientRect().height;
  const svgs = ["ov-main", "ov-budget", "ov-llm", "ov-hours"].map(id => document.querySelector(`#${id} svg.ovchart`));
  const fit = svgs.every(s => s && [...s.querySelectorAll("text.ax")].every(x => Math.abs(x.getBoundingClientRect().height - lh) <= 2));
  const said = svgs.every(s => { const l = s.nextElementSibling; return l?.matches("ul.vh") && l.children.length === s.querySelectorAll(".hit").length && l.children[0].textContent === s.querySelector(".hit").dataset.tip; });'
for w in 500 2000; do
  ck "Overview charts at $w px: axis text keeps --t-tiny, each point is in a hidden list, no sideways scroll" "true|true|true" "$(bash "$p" '#overview' --fixture "$F" --width $w --probe "$OVC"'
  return [fit, said, document.documentElement.scrollWidth <= innerWidth].join("|")')"
done
# Each axis has five distinct labels a round step apart: a money top under $4 gets cents; a count or minutes top under 4 ends at its whole peak.
ck "Overview chart axes: five distinct, even tick labels for tops 22, 45, 156, 100% and money 0.8 and 2; a count of 0.8 or 2 ends at 1 or 2" "true" "$(bash "$p" '#overview' --fixture "$F" --width 1280 --probe '
  const money = (v, ax) => ax >= 1 ? `$${Math.round(v)}` : usd(v), mins = v => `${Math.round(v)} min`, pct = v => `${Math.round(v)}%`, d = document.createElement("div");
  const ticks = (top, fmt, o) => { d.innerHTML = String(ovChart([{ t: Date.now(), v: top }], [["x", "var(--chart-1)", p => p.v]], fmt, o)); return [...d.querySelectorAll("text.ax[x=\"40\"]")].map(x => x.textContent); };
  const even = l => { const n = l.map(x => parseFloat(x.replace(/[^\d.]/g, ""))); return new Set(l).size === 5 && n.every((x, i) => Math.abs(x - n[0] - i * (n[1] - n[0])) < 1e-9) && n[4] >= 0; };
  const all = [0.8, 2, 22, 45, 156].flatMap(t => [ticks(t, money, { cents: true }), ...(t < 4 ? [] : [ticks(t, mins, { line: true }), ticks(t, v => String(Math.round(v)), {})])]).concat([ticks(100, pct, { line: true })]);
  const small = ticks(0.8, mins, { line: true }).join() === "0 min,1 min" && ticks(2, v => String(Math.round(v)), {}).join() === "0,1,2";
  return all.every(even) && small && ticks(100, pct, { line: true })[4] === "100%" && ticks(0.8, money, { cents: true })[1] === "$0.20" || JSON.stringify(all.filter(l => !even(l)))')"
# One stuck run flattened the Median run line: the axis stops below the outlier day, and its tip keeps the true value.
ck "Median run: one 3582-min day does not set the axis, its point sits at the top edge, its tip says 3582 min" "true|true|true" "$(bash "$p" '#overview' --fixture "$F" --width 1280 --probe "$SP"'
  STATS.rows.forEach((r, i) => { if (r.src === "pipeline") r.min = 20 + i % 30; }); STATS.rows.filter(r => r.src === "pipeline" && r.at === noon(8)).forEach(r => { r.min = 3582; });
  OV_RANGE = "90d"; OV_METRIC = "median"; renderOvMain(); const s = document.querySelector("#ov-main svg.ovchart"), ax = [...s.querySelectorAll("text.ax")].slice(0, 5).map(x => parseFloat(x.textContent));
  const ys = [...s.querySelectorAll("polyline.ln, circle")].flatMap(e => e.tagName === "circle" ? [+e.getAttribute("cy")] : e.getAttribute("points").split(" ").map(q => +q.split(",")[1]));
  return [ax[4] < 3582, Math.min(...ys) >= 8 - 0.1, [...s.querySelectorAll(".hit")].some(h => /Median run 3582 min/.test(h.dataset.tip))].join("|")')"
ck "The chart tip stays inside the window at the bottom edge" "true" "$(bash "$p" '#overview' --fixture "$F" --width 1280 --probe "$OVC"'
  const h = document.querySelector("#ov-hours .hit"), tip = document.getElementById("viztip");
  h.dispatchEvent(new MouseEvent("mousemove", { bubbles: true, clientX: 600, clientY: innerHeight - 2 }));
  return !tip.hidden && tip.getBoundingClientRect().bottom <= innerHeight')"
# A chart that grew with the width left an empty column under the 320px rail; the main chart keeps its 380px height.
for w in 1280 2000; do
  ck "Overview at $w px: the main chart keeps its 380px height" "true" "$(bash "$p" '#overview' --fixture "$F" --width $w --probe "$OVC"'
  return svgs[0].getBoundingClientRect().height <= 381')"
done
ck "The range buttons repaint after a click, a legend link sets the source, an old PR list hides the merged count, a 200 error body keeps the figures" "true|true|true|true" "$(bash "$p" '#overview' --fixture "$F" --width 1280 --probe "$SP"'
  const w = () => new Promise(r => setTimeout(r, 100)); render(); const b7 = document.querySelector("[data-ovrange=\"7d\"]"); b7.focus(); b7.click(); await w();
  const a = document.querySelector("[data-ovrange=\"7d\"]").getAttribute("aria-pressed") === "true" && document.querySelector("[data-ovrange=\"30d\"]").getAttribute("aria-pressed") === "false";
  document.querySelector("#ov-main [data-sfsrc=\"slack\"]").click(); await w(); const b = SF.src === "slack" && SF.range === "7d"; location.hash = "#overview"; await w();
  STATS = { ...STATS, prs_at: Math.round(Date.now() / 1000) - 7200 }; OV_RANGE = "30d"; OV_METRIC = "spend"; renderOvMain(); const c = !/merged that day/.test(document.querySelector("#ov-main").textContent);
  const keep = STATS, f0 = window.fetch; STATS_AT = 0; window.fetch = async u => String(u).includes("/api/stats") ? new Response(JSON.stringify({ error: "stats unavailable" })) : f0(u); await loadStats(); window.fetch = f0;
  return [a, b, c, STATS === keep && /could not be read \(stats unavailable\)/.test(document.querySelector("#ov-main").textContent)].join("|")')"
# The Overview fixture (sample data only, times relative to the run): every card renders, none errors.
O="$(dirname "$0")/page-fixture-overview.json"
ck "overview fixture: every card heading, no section error, relative times read as recent" "true|true|true" "$(bash "$p" '#overview' --fixture "$O" --width 1280 --probe '
  const hs = ["ov-main", "ov-needs", "ov-budget", "ov-runs", "ov-llm", "ov-hours", "ov-teams"].every(id => document.getElementById(id)?.textContent.trim().length > 0);
  OV_METRIC = "merged"; renderOvMain(); const m = document.querySelector("#ov-main [data-focus=\"ovm-open-merged\"] .big")?.textContent;
  return [hs, !document.getElementById("main").innerText.includes("did not render"), m === "6"].join("|")')"
# Overview layout: no sideways scroll at 500 (the smallest headless width) and 640, where the rail and the
# three cards stack; at 1280 the rail sits beside the chart and the three cards share a row. Belts and Teams still fit.
LAY='const top = id => document.getElementById(id).getBoundingClientRect().top, fits = document.documentElement.scrollWidth <= innerWidth;
  const side = Math.abs(top("ov-main") - top("ov-needs")) < 2, three = Math.abs(top("ov-runs") - top("ov-hours")) < 2;
  return [fits, side, three].join("|")'
ck "overview at 500 px: no sideways scroll, the rail and the three cards stacked" "true|false|false" "$(bash "$p" '#overview' --fixture "$O" --width 500 --probe "$LAY")"
ck "overview at 640 px: the same" "true|false|false" "$(bash "$p" '#overview' --fixture "$O" --width 640 --probe "$LAY")"
ck "overview at 1280 px: the rail beside the chart, the three cards in a row" "true|true|true" "$(bash "$p" '#overview' --fixture "$O" --width 1280 --probe "$LAY")"
# Metric tabs: the values in a row share one top, and no row has a lone tab.
MT='const rows = {}; for (const t of document.querySelectorAll("#ov-main .mt")) (rows[Math.round(t.getBoundingClientRect().top)] ??= []).push(Math.round(t.querySelector(".mv").getBoundingClientRect().top));
  const r = Object.values(rows); return [r.map(a => a.length).join(","), r.every(a => new Set(a).size === 1)].join("|")'
ck "metric tabs at 500, 768 and 1280 px: rows of 3+2, 3+2 and 5, the values level in each row" "3,2|true 3,2|true 5|true" "$(for w in 500 768 1280; do bash "$p" '#overview' --fixture "$O" --width $w --probe "$MT"; done | paste -sd' ' -)"
# Needs you at 1080, where the rail is two columns: the rail row ends at the content of its taller card, and each reason has its own line and a title.
ck "Needs you at 1080 px: no empty stretch, the reason on its own line with its full text in a title" "true|true|true" "$(bash "$p" '#overview' --fixture "$O" --width 1080 --probe '
  const c = document.getElementById("ov-needs"), s4 = parseFloat(getComputedStyle(c).getPropertyValue("--s4")), w = c.querySelector(".nrow .why"), k = c.querySelector(".nrow .key");
  const gap = x => x.getBoundingClientRect().bottom - x.lastElementChild.getBoundingClientRect().bottom;
  return [Math.min(gap(c), gap(document.getElementById("ov-budget"))) <= parseFloat(getComputedStyle(c).paddingBottom) + s4,
    w.getBoundingClientRect().top >= k.getBoundingClientRect().bottom, w.title === w.textContent].join("|")')"
# Needs you and the month's spend side by side in the rail end at one bottom, so neither card has empty space below it.
ck "rail at 768 and 1080 px: two cards in one row end within 1px of each other" "true true" "$(for w in 768 1080; do bash "$p" '#overview' --fixture "$O" --width $w --probe '
  const r = id => document.getElementById(id).getBoundingClientRect(), n = r("ov-needs"), b = r("ov-budget");
  return Math.abs(n.top - b.top) > 1 || Math.abs(n.bottom - b.bottom) <= 1'; done | paste -sd' ' -)"
# The cards in a row share one height: Activity, LLM spend and Runs by hour, and the main card beside the rail.
ck "overview at 1080, 1280 and 2000 px: the three cards share a height and the main card ends at the rail" "true|true true|true true|true" "$(for w in 1080 1280 2000; do bash "$p" '#overview' --fixture "$O" --width $w --probe '
  const r = id => document.getElementById(id).getBoundingClientRect(), hs = ["ov-runs", "ov-llm", "ov-hours"].map(id => r(id).height), m = r("ov-main"), rl = document.querySelector(".ovgrid > .ovrail").getBoundingClientRect();
  return [Math.max(...hs) - Math.min(...hs) < 1, Math.abs(m.top - rl.top) > 1 || Math.abs(m.bottom - rl.bottom) < 1].join("|")'; done | paste -sd' ' -)"
# The legend under the spend chart gives each source's spend and run count; a stale-feed note is in the warn colour.
ck "overview: the legend gives each source's runs, and a feed note has the warn colour" "true|true" "$(bash "$p" '#overview' --fixture "$O" --width 1280 --probe '
  OV_METRIC = "spend"; renderOvMain(); const leg = /runs/.test(document.querySelector("#ov-main .ovleg")?.textContent ?? "");
  const d = document.createElement("div"); d.className = "ovknote"; document.getElementById("ov-main").append(d);
  return [leg, getComputedStyle(d).color === getComputedStyle(document.documentElement).getPropertyValue("--warn").trim().replace(/^#(..)(..)(..)$/, (_, r, g, b) => `rgb(${parseInt(r, 16)}, ${parseInt(g, 16)}, ${parseInt(b, 16)})`)].join("|")')"
for r in '#pipeline/belts' '#teams'; do
  ck "$r at 500 px still has no sideways scroll" "true" "$(bash "$p" "$r" --fixture "$F" --width 500 --probe 'return document.documentElement.scrollWidth <= innerWidth')"
done
# Epic review 1 fixes: the Merged and Cost links open Stats PRs on 7 days and agree with it; a stale agents feed
# is unknown on the chip and on Needs you.
ck "review 1: the Cost link opens Stats PRs on 7 days with the same figure; a stale agents feed is unknown on the chip and Needs you" "true|true" "$(bash "$p" '#overview' --fixture "$O" --width 1280 --probe '
  const w = () => new Promise(r => setTimeout(r, 150)); localStorage.setItem("statsFilter", JSON.stringify({ ...SF_DEFAULT, range: "30d" })); SF = { ...SF_DEFAULT, range: "30d" };
  OV_METRIC = "merged"; renderOvMain(); const lk = document.querySelector("#ov-main [data-focus=\"ovm-open-cost\"]"), card = lk.querySelector(".big").textContent; lk.click(); await w();
  const kpi = [...document.querySelectorAll("#s-stats .stat")].find(c => c.querySelector(".lbl").textContent === "Cost per merged PR")?.querySelector(".big").textContent;
  const a = location.hash === "#stats/prs" && SF.range === "7d" && kpi === card;
  location.hash = "#overview"; await w(); STATE.agents_age_seconds = 1200; STATE.agents_interval = 30; render();
  const c = /^\? at work now/.test(document.querySelector("#ov-head .tag.run").textContent) && /\?/.test(document.querySelector("#ov-needs .big").textContent);
  return [a, c].join("|")')"
ck "review 2: 'Merged, 7 days' on Overview equals the Stats PRs Merged card it opens, for a PR opened 10 days ago" "2|2" "$(bash "$p" '#overview' --fixture "$O" --width 1280 --probe '
  const w = () => new Promise(r => setTimeout(r, 150)), ago = d => new Date(Date.now() - d * 86400000).toISOString();
  STATS = { ...STATS, prs: [{ n: 1, key: "EX-1", title: "a", state: "MERGED", src: "pipeline", created: ago(10), merged: ago(1) }, { n: 2, key: "EX-2", title: "b", state: "MERGED", src: "pipeline", created: ago(2), merged: ago(1) }] };
  OV_METRIC = "merged"; renderOvMain(); const lk = document.querySelector("#ov-main [data-focus=\"ovm-open-merged\"]"), o = lk.querySelector(".big").textContent; lk.click(); await w();
  return [o, [...document.querySelectorAll("#s-stats .stat")].find(c => c.querySelector(".lbl").textContent === "Merged")?.querySelector(".big").textContent].join("|")')"
# Epic review 3: the range buttons keep the focus; Stats PRs shows a week of merges of older PRs.
ck "review 3: range buttons keep the focus across a click and a poll; Stats PRs shows merges of older PRs" "true|1|1" "$(bash "$p" '#overview' --fixture "$O" --width 1280 --probe '
  const w = () => new Promise(r => setTimeout(r, 150)), ago = d => new Date(Date.now() - d * 86400000).toISOString();
  const b = document.querySelector("[data-ovrange=\"7d\"]"); b.focus(); b.click(); await w(); AGENTS.runners[0].agent_alive = false; render(); await w();
  const a = document.activeElement?.dataset.focus === "ovr-7d" && document.querySelector("[data-ovrange=\"7d\"]").getAttribute("aria-pressed") === "true";
  STATS = { ...STATS, prs: [{ n: 1, key: "EX-1", title: "a", state: "MERGED", src: "pipeline", created: ago(10), merged: ago(2) }] }; OV_METRIC = "merged"; renderOvMain();
  const lk = document.querySelector("#ov-main [data-focus=\"ovm-open-merged\"]"), o = lk.querySelector(".big").textContent; lk.click(); await w();
  const k = [...document.querySelectorAll("#s-stats .stat")].find(c => c.querySelector(".lbl").textContent === "Merged")?.querySelector(".big").textContent;
  SF = { ...SF, src: "slack" }; LAST["s-stats"] = ""; renderStats(); const k2 = /No PR opened or merged in this range matches these filters/.test(document.getElementById("s-stats").textContent);
  return [a, o, k2 ? k : "filter ignored"].join("|")')"
ck "O6 KPIs: a good or bad change also says better or worse in words, not by colour alone" "+50%, worse, vs|+25 pts, better, vs|false" "$(bash "$p" '#overview' --fixture "$O" --width 1280 --probe '
  const DAY = 86400000, iso = d => new Date(Date.now() - d * DAY).toISOString(), P = (d, pr, min, usd) => ({ at: iso(d), src: "pipeline", pr, min, usd, key: "K" });
  STATS = { ...STATS, rows: [P(1, true, 10, 10), P(1, true, 20, 10), P(2, true, 30, 5), P(2, false, 40, 5), P(9, true, 10, 10), P(9, false, 12, 10), P(20, true, 1, 1)] }; STATS_ERR = null; OV_RANGE = "7d"; renderOvMain();
  const t = f => document.querySelector(`#ov-main [data-ovmetric="${f}"] .mc`).textContent;
  return [t("spend").replace(/ the .*/, ""), t("rate").replace(/ the .*/, ""), /better|worse/.test(t("runs"))].join("|")')"
# Overview at a glance (O6): the KPI change, Teams by profile, Recent runs and its failed read.
# The row 20 days ago starts the log before the period before, so the change shows.
ck "O6 KPIs: the change against the period before in %, points and minutes, colored by which way is good" "+50%|bad|+25 pts|good|+14 min|bad|75%" "$(bash "$p" '#overview' --fixture "$O" --width 1280 --probe '
  const DAY = 86400000, iso = d => new Date(Date.now() - d * DAY).toISOString(), P = (d, pr, min, usd) => ({ at: iso(d), src: "pipeline", pr, min, usd, key: "K" });
  STATS = { ...STATS, rows: [P(1, true, 10, 10), P(1, true, 20, 10), P(2, true, 30, 5), P(2, false, 40, 5), P(9, true, 10, 10), P(9, false, 12, 10), P(20, true, 1, 1)] }; STATS_ERR = null; OV_RANGE = "7d"; renderOvMain();
  const g = f => { const c = document.querySelector(`#ov-main [data-ovmetric="${f}"] .chg`); return [c?.textContent, c?.classList.contains("good") ? "good" : c?.classList.contains("bad") ? "bad" : ""]; };
  return [...g("spend"), ...g("rate"), ...g("median"), document.querySelector("#ov-main [data-ovmetric=\"rate\"] .mv").textContent].join("|")')"
ck "Rate and Median run with no pipeline row: an empty box, not an empty axis" "true|true" "$(bash "$p" '#overview' --fixture "$O" --width 1280 --probe '
  STATS = { ...STATS, rows: [{ at: new Date(Date.now() - 86400000).toISOString(), src: "slack", usd: 1 }] }; STATS_ERR = null; OV_RANGE = "7d";
  return ["rate", "median"].map(m => { OV_METRIC = m; renderOvMain(); const c = document.getElementById("ov-main"); return !c.querySelector(".ovchart") && /No pipeline run in the last/.test(c.querySelector(".emptybox")?.textContent ?? ""); }).join("|")')"
ck "O6 Teams: rows by stats profile (none is fxa), work now by team, runs and PRs in the range, the budget bar, no link for a bad name" "fxa|1,2,1|0,1,0|warn 90%|no link" "$(bash "$p" '#overview' --fixture "$O" --width 1280 --probe '
  const iso = d => new Date(Date.now() - d * 86400000).toISOString();
  TEAMS = { teams: [{ profile: "two", label: "Two", access: { open: true }, budget: { month_usd: 45, month_cap: 50 } }, { profile: "fxa", label: "FxA" }, { profile: "../x", label: "Bad" }] };
  STATS = { ...STATS, rows: [{ at: iso(1), src: "pipeline", pr: true, usd: 3 }, { at: iso(1), src: "slack", usd: 1, profile: "fxa" }, { at: iso(2), src: "slack", usd: 2, profile: "two" }, { at: iso(40), src: "slack", usd: 9, profile: "two" }] };
  OV_RANGE = "30d"; renderOvTeams(); const r = p => document.querySelector(`#ov-teams [data-team="${p}"]`), nums = p => [...r(p).querySelectorAll(".num")].map(e => e.lastChild.textContent).join(","), bar = r("two").querySelector(".meter i");
  return [document.querySelector("#ov-teams [data-team]").dataset.team, nums("fxa"), nums("two"), `${bar.className} ${bar.style.width}`, r("../x").querySelector("a") ? "link" : "no link"].join("|")')"
ck "O6 Teams: a table with named columns, the team name links, and the cap text says the month" "Team,Now,Runs,PRs,Spend|FxA|no cap|\$5.00 of \$50.00 this month" "$(bash "$p" '#overview' --fixture "$O" --width 1280 --probe '
  TEAMS = { teams: [{ profile: "fxa", label: "FxA", access: { open: true } }, { profile: "two", label: "Two", access: { open: true }, budget: { month_usd: 5, month_cap: 50 } }] }; OV_RANGE = "30d"; renderOvTeams();
  const h = p => document.querySelector(`#ov-teams [data-team="${p}"] td.bud .hint`).textContent;
  return [[...document.querySelectorAll("#ov-teams th")].map(t => t.textContent).join(","), document.querySelector("#ov-teams [data-team=fxa] a").textContent, h("fxa"), h("two")].join("|")')"
ck "O6 Recent runs: a badge per outcome, PR links only to GitHub pulls, merged from pr_state, today's counts, escaped" "PR #312|running|done|PR #301 merged|answered|no change|failed|true|true" "$(bash "$p" '#overview' --fixture "$O" --width 1280 --probe '
  const bs = [...document.querySelectorAll("#ov-runs .ovrun .r .tag")].map(e => e.textContent);
  const a = document.querySelector("#ov-runs a.tag[href=\"https://github.com/example/repo/pull/301\"]")?.classList.contains("ok") && /(\d+ today|none today)/.test(document.querySelector("#ov-runs > .sub").textContent);
  RUNS = [{ at: new Date().toISOString(), src: "pipeline", key: "x\"><img src=x>", title: "<img src=x>", team: "<b>t</b>", outcome: "pr", pr_url: "javascript:alert(1)", pr_number: 5 }]; renderOvRuns();
  const b = !document.querySelector("#ov-runs img, #ov-runs b") && !document.querySelector("#ov-runs a.tag") && /PR #5/.test(document.getElementById("ov-runs").textContent);
  return [...bs, a, b].join("|")')"
for w in 768 1080; do ck "O6 Activity at $w: the h2 is as tall as the LLM h2, the link is one line, the day count is a sub line, a long title is one line with its full text in title, the key is never cut" "true|true|true|true" "$(bash "$p" '#overview' --fixture "$O" --width "$w" --probe '
  const k = "FXA-14809", tt = "fix(functional-tests): a very long run title that cannot fit in one line of this narrow card at all";
  RUNS = [{ at: new Date().toISOString(), src: "pipeline", key: k, title: tt, outcome: "pr", pr_number: 5 }]; renderOvRuns();
  const h = id => document.querySelector(`#${id} h2`).getBoundingClientRect().height, a = document.querySelector("#ov-runs h2 a"), t = document.querySelector("#ov-runs .ovrun .t");
  const lh = parseFloat(getComputedStyle(t).lineHeight);
  return [Math.abs(h("ov-runs") - h("ov-llm")) < 2, a.getClientRects().length === 1 && a.getBoundingClientRect().height < 2 * lh, /today/.test(document.querySelector("#ov-runs > .sub").textContent), t.title === `${k} ${tt}` && t.clientHeight < 1.5 * lh && t.querySelector(".key").getBoundingClientRect().right <= t.getBoundingClientRect().right + 1].join("|")')"; done
ck "O6 review: a failed stats feed puts its note on Teams and Recent runs and the Teams figures say unknown; today counts every stats row, not the card's" "true|true|true|true" "$(bash "$p" '#overview' --fixture "$O" --width 1280 --probe '
  const tm = () => document.getElementById("ov-teams").textContent, rn = () => document.getElementById("ov-runs").textContent;
  const now = new Date().toISOString(); STATS.rows ??= []; for (let i = 0; i < 14; i++) STATS.rows.push({ at: now, src: "pipeline", key: "EX-9" + i, kind: "fix", usd: 1, min: 3, pr: i < 5, profile: "example" });
  safeRender(renderOvRuns, "ov-runs"); const n = (rn().match(/(\d+) today/) || [])[1], cnt = Number(n) >= 14 && Number(n) > RUNS.length;
  STATS_ERR = "the stats read failed"; safeRender(renderOvTeams, "ov-teams"); safeRender(renderOvRuns, "ov-runs");
  const r = [/the stats read failed/i.test(tm()), /the stats read failed/i.test(rn()), !/\$\d/.test([...document.querySelectorAll("#ov-teams td.bud b")].map(b => b.textContent).join("")), cnt];
  STATS_ERR = null; return r.join("|")')"
ck "O6 Recent runs: no endpoint, an error body and an HTTP error each say unavailable, never an empty list" "true|true|true" "$(bash "$p" '#overview' --fixture "$F" --width 1280 --probe '
  const t = () => document.getElementById("ov-runs").textContent, f0 = window.fetch, a = /Recent runs unavailable: the answer has no runs/.test(t());
  window.fetch = async u => String(u).includes("/api/runs/recent") ? new Response(JSON.stringify({ runs: [], error: "stats unavailable" })) : f0(u); await loadRuns(); const b = /Recent runs unavailable: stats unavailable/.test(t());
  window.fetch = async u => String(u).includes("/api/runs/recent") ? new Response("nope", { status: 404 }) : f0(u); await loadRuns(); window.fetch = f0;
  return [a, b, /Recent runs unavailable: HTTP 404/.test(t()) && !document.querySelector("#ov-runs .ovrun")].join("|")')"
# The new Overview cards (O7): LLM spend, the month's budget, runs by hour, the slim /api/overview slice, Needs you rows.
ck "O7 LLM: 14 days and the cost by model from the full feed or the slim slice, the last hour, a stale feed is unknown" "true|true|true" "$(bash "$p" '#overview' --fixture "$O" --width 1280 --probe '
  const days = [...Array(20)].map((_, i) => ({ day: new Date(Date.now() - (19 - i) * 86400000).toISOString().slice(0, 10), usd: i }));
  STATS = { ...STATS, llm: { hour_usd: 0.42, days, models: [{ day: days[19].day, model: "claude-opus-5-5", usd: 6 }, { day: days[6].day, model: "claude-opus-5-5", usd: 1 }, { day: days[6].day, model: "claude-sonnet-5-5", usd: 3.6 }, { day: days[5].day, model: "claude-opus-5-5", usd: 50 }] } }; STATS_ERR = null; renderOvLlm();
  const t = document.getElementById("ov-llm").textContent, a = /\$0\.42 last hour/.test(t) && /Opus 5\.5\$7\.00/.test(t) && /Sonnet 5\.5\$3\.60/.test(t) && document.querySelectorAll("#ov-llm .ovchart .hit").length === 14;
  const full = STATS; STATS = null; OV = { rows: [], prs: [], llm: { hour_usd: 0.1, days: days.slice(-3), models: { "claude-opus-5-5": 2 } } }; renderOvLlm();
  const b = /\$0\.10 last hour/.test(document.getElementById("ov-llm").textContent) && /Opus 5\.5\$2\.00/.test(document.getElementById("ov-llm").textContent); STATS = full;
  STATE.stats_age_seconds = 9999; STATE.stats_interval = 60; renderOvLlm(); const c = /last hour unknown/.test(document.getElementById("ov-llm").textContent);
  return [a, b, c].join("|")')"
ck "O7 LLM: 14 UTC dates with a quiet day as \$0.00, a day past the UTC date left out, the card says UTC" "true|true|true" "$(bash "$p" '#overview' --fixture "$O" --width 1280 --probe '
  const k = i => new Date(Date.now() - i * 86400000).toISOString().slice(0, 10), gone = k(3);
  STATS = { ...STATS, llm: { hour_usd: 0, days: [...Array(16)].map((_, i) => ({ day: k(15 - i), usd: 2 })).filter(d => d.day !== gone).concat({ day: k(-1), usd: 99 }), models: [] } }; STATS_ERR = null; renderOvLlm();
  const tips = [...document.querySelectorAll("#ov-llm .ovchart .hit")].map(r => r.dataset.tip), sd = s => new Date(`${s}T00:00`).toLocaleDateString(undefined, { month: "short", day: "numeric" });
  return [tips.length === 14, tips[10] === `${sd(gone)}: LLM, UTC day $0.00` && tips[13].startsWith(`${sd(k(0))}:`) && !tips.some(t => /99/.test(t)), /By UTC date/.test(document.querySelector("#ov-llm > .sub").textContent)].join("|")')"
ck "O7 Budget: every team by day from the rows; a capped team's meter is its budget record, not the rows; a team past its cap rate gets the date; no cap says so" "true|true|true|true" "$(bash "$p" '#overview' --fixture "$O" --width 1280 --probe '
  const now = new Date(), d = new Date(now.getFullYear(), now.getMonth(), 1, 12).toISOString();
  STATS = { ...STATS, rows: [{ at: d, src: "pipeline", usd: 7, profile: "example" }, { at: new Date().toISOString(), src: "slack", usd: 3, profile: "sample-two" }] }; STATS_ERR = null;
  TEAMS = { teams: [{ profile: "example", label: "Example", budget: { month_usd: 1, month_cap: null } }, { profile: "sample-two", label: "Sample Two", budget: { month_usd: 49, month_cap: 50 } }] }; renderOvBudget();
  const t = document.getElementById("ov-budget").textContent, a = /\$10\.00/.test(t), b = /Sample Two\$49\.00 of \$50\.00/.test(t) && !/Example\$/.test(t);
  const c = now.getDate() === new Date(now.getFullYear(), now.getMonth() + 1, 0).getDate() || /passes the cap on/.test(t);
  TEAMS = { teams: [{ profile: "example", label: "Example", budget: { month_usd: 1, month_cap: null } }] }; renderOvBudget();
  return [a, b, c, /No team has a monthly budget cap/.test(document.getElementById("ov-budget").textContent)].join("|")')"
# The month rate counts the days elapsed to now: at 00:30 on Oct 2, $10.20 spent is near $10 a day, not $5.10.
ck "O7 Budget: the projection and the cap date use the elapsed days, and a legend names Spent and Projected" "true|true|Spent \$10.20|Projected \$309.75" "$(TZ=America/New_York bash "$p" '#overview' --fixture "$O" --width 1280 --probe '
  const D0 = Date, T = new D0(2026, 9, 2, 0, 30).getTime(); Date = class extends D0 { constructor(...a) { super(...(a.length ? a : [T])); } static now() { return T; } };
  STATS = { ...STATS, rows: [{ at: new D0(2026, 9, 1, 12).toISOString(), src: "pipeline", usd: 10.2, profile: "example" }] }; STATS_ERR = null;
  TEAMS = { teams: [{ profile: "example", label: "Example", budget: { month_usd: 10.2, month_cap: 100 } }] }; try { renderOvBudget(); } finally { Date = D0; }
  const n = document.getElementById("ov-budget"), leg = [...n.querySelectorAll(".ovleg span")].map(x => x.textContent.trim());
  return [/ends near \$309\.75/.test(n.textContent), new RegExp(`passes the cap on ${shortDay(new D0(2026, 9, 11).getTime())}\\.`).test(n.textContent), ...leg].join("|")')"
# The first and last x labels sat past the plot: "Oct 31" ran into the card padding and "Oct 1" hit the "$0" y label.
for w in 500 1280 2000; do
  ck "O7 Budget at $w px: the x labels stay inside the chart and no axis label overlaps another" "true|true" "$(bash "$p" '#overview' --fixture "$O" --width $w --probe '
  const s = document.querySelector("#ov-budget svg.ovchart"), sb = s.getBoundingClientRect(), r = [...s.querySelectorAll("text.ax")].map(x => x.getBoundingClientRect());
  const hit = (a, b) => a.left < b.right - .5 && b.left < a.right - .5 && a.top < b.bottom - .5 && b.top < a.bottom - .5;
  return [r.length > 5 && r.every(b => b.left >= sb.left - .5 && b.right <= sb.right + .5), !r.some((a, i) => r.slice(i + 1).some(b => hit(a, b)))].join("|")')"
done
ck "O7 Runs by hour: the last 24 hours, passes not counted, the busiest hour named" "3 runs|true|true" "$(bash "$p" '#overview' --fixture "$O" --width 1280 --probe '
  const ago = h => new Date(Date.now() - h * 3600000).toISOString();
  STATS = { ...STATS, rows: [{ at: ago(1), src: "pipeline" }, { at: ago(1), src: "slack" }, { at: ago(5), src: "answer" }, { at: ago(1), src: "pass" }, { at: ago(30), src: "pipeline" }] }; STATS_ERR = null; renderOvHours();
  const t = document.getElementById("ov-hours").textContent;
  return [t.match(/\d+ runs?/)?.[0], /Busiest: .*2 runs/.test(t), document.querySelectorAll("#ov-hours .ovchart .hit").length === 24].join("|")')"
# A tie names no busiest hour; in a zone 30 minutes off UTC each bucket still starts on a local hour.
ck "O7 Runs by hour: a tie says at most N, and the buckets start on local hours in Asia/Kolkata" "true|true" "$(TZ=Asia/Kolkata bash "$p" '#overview' --fixture "$O" --width 1280 --probe '
  const ago = h => new Date(Date.now() - h * 3600000).toISOString();
  const h0 = new Date(); h0.setMinutes(0, 0, 0); const p1 = h0.getTime() - 3600000 + 60000;
  STATS = { ...STATS, rows: [{ at: new Date(p1).toISOString(), src: "pipeline" }, { at: ago(5), src: "slack" }] }; STATS_ERR = null; renderOvHours();
  const t = document.getElementById("ov-hours").textContent, tips = [...document.querySelectorAll("#ov-hours .ovchart .hit")].map(h => h.dataset.tip);
  const lbl = new Date(p1).toLocaleTimeString([], { hour: "numeric" });
  return [!/Busiest/.test(t) && /At most 1 run in an hour/.test(t), new Date().getTimezoneOffset() === -330 && tips[22] === `${lbl}: Runs 1`].join("|")')"
ck "overview at 768 px: runs by hour takes the whole second row of the three cards" "true" "$(bash "$p" '#overview' --fixture "$O" --width 768 --probe '
  const r = id => document.getElementById(id).getBoundingClientRect(), g = document.querySelector(".ov3").getBoundingClientRect();
  return Math.abs(r("ov-hours").width - g.width) < 2 || Math.abs(r("ov-hours").top - r("ov-runs").top) < 2')"
ck "O7 slim slice: before /api/stats lands the Overview draws from /api/overview; the full feed then takes over; a bad answer is ignored" "true|true|true" "$(bash "$p" '#overview' --fixture "$O" --width 1280 --probe '
  const f0 = window.fetch, full = STATS, t = Date.now() - 3600000;
  window.fetch = async u => String(u).includes("/api/overview") ? new Response(JSON.stringify({ cols: ["ms", "src", "usd", "pr", "min", "profile", "compute_usd"], rows: [[t, "pipeline", 12.5, 1, 9, "example", 0]], merged: [new Date(t).toISOString()], prs_at: Math.round(Date.now() / 1000), llm: { hour_usd: 0.05, days: [], models: {} } })) : f0(u);
  STATS = null; OV = null; await loadOverview(); window.fetch = f0;
  const a = OV?.slim && document.querySelector("#ov-main [data-ovmetric=\"spend\"] .mv").textContent === "$12.50" && OV.rows[0].pr === 1 && OV.prs.length === 1;
  STATS = full; render(); const b = document.querySelector("#ov-main [data-ovmetric=\"spend\"] .mv").textContent !== "$12.50";
  const keep = OV; window.fetch = async u => String(u).includes("/api/overview") ? new Response("{}") : f0(u); await loadOverview(); window.fetch = f0;
  return [a, b, OV === keep].join("|")')"
ck "O7 Needs you: a row per belt that needs a person, each linking its belt, the reason escaped" "true|true" "$(bash "$p" '#overview' --fixture "$O" --width 1280 --probe '
  const r = document.querySelector("#ov-needs .nrow"), bg = beltGroups().needs[0];
  return [!!r && r.getAttribute("href") === `#pipeline/belts/${encodeURIComponent(bg.t.key)}`, !document.querySelector("#ov-needs .nrow .why img")].join("|")')"
# i407 sb-cards: the cards read the 7 day Stats rows and the agents feed, say what the host costs, and never show a 0 for an unknown feed.
C="$(dirname "$0")/page-fixture-sb-cards.json"
ck "i407 cards: 7 day runs and sessions, the cost lines, the host state from fc_state, a GCE session, and an unknown stats feed" "true|true|true|true|true|true|true|true|true|true|true" "$(bash "$p" '#runners' --fixture "$C" --width 1280 --probe '
  const now = Date.now() / 1000, iso = s => new Date((now - s) * 1000).toISOString(), n = document.getElementById("sb-cards");
  const rows = []; for (let i = 0; i < 41; i++) rows.push({ at: iso(3600 * (i + 1)), src: "pipeline", key: "EX-" + i, min: i ? 92 : 100, profile: "example" });
  const sl = (i, o) => Object.assign({ at: iso(3600 * (i + 1)), src: "slack", key: "agent-s" + i, profile: "example", backend: null, t0: null, end: null, boot_s: null }, o);
  for (let i = 0; i < 20; i++) rows.push(sl(i, i === 0 ? { boot_s: 30 } : i === 1 ? { boot_s: 41 } : i === 2 ? { boot_s: 60 } : {}));
  rows.push(sl(20, { backend: "firecracker", t0: now - 36000, end: now - 28800 }), sl(21, { backend: "firecracker", t0: now - 32400, end: now - 25200 }), sl(22, { backend: "gce", t0: now - 18000, end: now - 14400 }), { at: iso(9 * 86400), src: "pipeline", key: "EX-OLD", min: 500 });
  STATS.rows = rows; STATS.load = { cap: 4, days: [{ day: new Date().toISOString().slice(0, 10), peak: 3 }] }; STATS_ERR = null;
  const t = () => n.textContent.replace(/\s+/g, " "), hostKv = () => [...n.querySelectorAll(".kv")].some(k => /Firecracker/.test(k.textContent) && /always on|%/.test(k.textContent));
  renderSbCards(); const a = t(), noHostAlways = !hostKv() && !/%/.test(a);
  AGENTS.sessions[0].boot_backend = "firecracker"; renderSbCards(); const b = t();
  AGENTS.infra.fc_state = "none"; renderSbCards(); const c = t();
  AGENTS.sessions.push({ key: "agent-ex0002", state: "active", boot_backend: "gce", created: now - 60 }); renderSbCards(); const d = t(), gseg = !!n.querySelector(".sbstrip i.gce");
  STATS_ERR = "stats read failed"; renderSbCards(); const e = t();
  return [/7 days: 41 runs, 63 h/.test(a), /7 days: 23 sessions, peak 3 of 4 · boot median 41 s/.test(a), /Manager ?\$0\.21\/h · \$35 in 7 days, always on/.test(a), /Firecracker host ?stopped: it starts for the next session/.test(a),
    /Sessions used the host 3 h in 7 days/.test(a), /GCE sandboxes now ?\$0\.13\/h/.test(a), noHostAlways, /Firecracker host ?state unknown: the host did not answer/.test(b), !/Firecracker/.test(c),
    /2 of 4 busy/.test(d) && /1 on GCE/.test(d) && gseg, /7 days: unknown: Stats read failed/.test(e) && !/7 days: 0|used the host 0/.test(e)].join("|")')"
ck "i407 cards: an old agents feed gives ? on each card, not a 0" "3|false" "$(bash "$p" '#runners' --fixture "$C" --width 1280 --probe '
  const n = document.getElementById("sb-cards"); STATE.agents_age_seconds = 99999; renderSbCards();
  return [...n.querySelectorAll(".big")].filter(b => b.textContent === "?").length + "|" + /\b0 of|\$0\.00/.test(n.textContent)')"
ck "i407 cards review: the stats load repaints Sandboxes; an open row with no end adds no host hours; the strip label says free slots unknown; no peak is '?'; before the first stats poll it says Loading" "true|true|true|true|true" "$(bash "$p" '#runners' --fixture "$C" --width 1280 --probe '
  await new Promise(r => setTimeout(r, 400)); const n = document.getElementById("sb-cards"), t = () => n.textContent.replace(/\s+/g, " "), now = Date.now() / 1000;
  const loaded = /7 days: \d+ runs/.test(t());
  STATS.rows = [{ at: new Date((now - 3600) * 1000).toISOString(), src: "slack", key: "agent-s1", backend: "firecracker", t0: now - 3 * 86400, end: null, live: false }]; STATS_ERR = null; STATE.stats_age_seconds = 1; renderSbCards();
  const noOpen = !/Sessions used the host [1-9]/.test(t());
  AGENTS.free_slots = null; renderSbCards(); const aria = /free slots unknown/.test(n.querySelector(".sbstrip")?.getAttribute("aria-label") || "");
  AGENTS.free_slots = []; STATS.load = undefined; renderSbCards(); const pk = /peak \? of/.test(t()) && !/peak (0|NaN)/.test(t());
  STATS = null; STATS_ERR = null; renderSbCards(); const ld = /7 days: Loading the stats…/.test(t()) && !/could not be read/.test(t());
  return [loaded, noOpen, aria, pk, ld].join("|")')"
# Sandboxes panel (i407 sb-panel): a selected row opens the panel; when a poll drops it, the selection clears, the drawer closes
# and the focus goes to the list. sbRows() is stubbed here until sb-list-fixes builds it.
SP="$(dirname "$0")/page-fixture-sb-panel.json"
ck "sb-panel: a fix row opens with its command; when the row leaves, SEL.runners clears, showright is off, the focus is in #sb-list" "true|true|true|true" "$(bash "$p" '#runners' --fixture "$SP" --width 1200 --probe '
  const rows = { live: [], fix: [{ id: "fix:agent-def456", src: "slack", key: "agent-def456", fix: { why: "The runner is still up 10 min after its session stopped.", cmd: "fxa-sandbox-ctl stop agent-def456", steps: null } }] };
  window.sbRows = () => rows; window.sbTabHas = () => true;
  if (!document.getElementById("sb-list")) { const d = document.createElement("div"); d.id = "sb-list"; document.querySelector("main").appendChild(d); }
  SEL.runners = "fix:agent-def456"; document.body.classList.add("showright"); renderRight();
  const open = document.getElementById("right").innerHTML.includes("<code>fxa-sandbox-ctl stop agent-def456</code>");
  document.getElementById("rclose")?.focus(); rows.fix = []; renderRight();
  return [open, SEL.runners === undefined, !document.body.classList.contains("showright"), document.getElementById("sb-list").contains(document.activeElement)].join("|")')"
D="$(dirname "$0")/page-fixture-sb-done.json"
ck "Sandboxes Recently completed: ended runs newest first, the PR link, and a phone-width table scrolls in its own box" "agent-sl0001,EX-1|true|true|true" "$(bash "$p" '#runners' --fixture "$D" --width 500 --probe '
  let s = document.getElementById("s-sb"); if (!s) { s = document.createElement("section"); s.id = "s-sb"; s.className = "wide"; document.getElementById("main").append(s); }
  let d = document.getElementById("sb-done"); if (!d) { d = document.createElement("div"); d.id = "sb-done"; d.className = "sb-done"; s.append(d); }
  d.style.width = "360px"; await loadSbDone();
  const box = d.querySelector(".sbd-scroll");
  return [[...d.querySelectorAll("[data-sbdone]")].map(x => x.dataset.sbdone).join(","), !!d.querySelector("a[href=\"https://github.com/example/repo/pull/41\"]"),
    !!box && box.scrollWidth > box.clientWidth && getComputedStyle(box).overflowX === "auto", document.documentElement.scrollWidth <= innerWidth].join("|")')"
ck "Sandboxes review: at 1440 px a long For title ends in an ellipsis and every column, the Result too, fits without a side scroll" "true|true" "$(bash "$p" '#runners' --fixture "$D" --width 1440 --probe '
  await loadSbDone(); SB_DONE.runs[0].title = "A very long sample request that keeps going and going so that it would push every later column of the table off to the right side"; renderSbDone();
  const box = document.querySelector("#sb-done .sbd-scroll"), res = document.querySelector("#sb-done tbody tr td:last-child");
  return [box.scrollWidth <= box.clientWidth, res.getBoundingClientRect().right <= box.getBoundingClientRect().right + 1].join("|")')"
ck "Overview review: a routine run the server gated (no key, team or cost) still renders in Recent runs" "true|false" "$(bash "$p" '#overview' --fixture "$O" --width 1280 --probe '
  RUNS = [{ at: new Date().toISOString(), src: "slack", kind: "session", key: "", title: "Scheduled run", team: "", outcome: "answered", pr_url: null, pr_number: null, pr_state: null, usd: null, min: null, routine: true }]; RUNS_ERR = null;
  safeRender(renderOvRuns, "ov-runs"); const t = document.getElementById("ov-runs").textContent;
  return [/Scheduled run/.test(t), /undefined|NaN|\$0\.00|did not render/.test(t)].join("|")')"
ck "only the short GCE states count as moving, and a moving instance with no age and no run is unknown, not hidden" "false|true|stopping|true" "$(bash "$p" '#runners' --fixture "$B" --width 1280 --probe '
  const m = [instMoving({ state: "stopped" }), instMoving({ state: "suspending" }), movingWord({ state: "suspending" })];
  AGENTS.instances = [...(AGENTS.instances ?? []), { name: "agent-agent-nn0001", state: "staging", age_seconds: null }];
  const r = sbRows(); return [...m, r.unknown.some(x => x.slot === "agent-agent-nn0001")].join("|")')"
w=""; for v in '#overview' '#runners' '#pipeline' '#stats' '#teams' '#sessions'; do w="$w$(bash "$p" "$v" --fixture "$O" --width 1440 --probe 'return document.documentElement.scrollWidth <= innerWidth')"; done
ck "no view scrolls sideways at 1440 px: a hidden right panel takes no width" "truetruetruetruetruetrue" "$w"
# WCAG 1.4.11: a chart series needs 3:1 against the card, in both themes.
cc='const v = n => getComputedStyle(document.documentElement).getPropertyValue(n).trim(), L = h => { const c = [1, 3, 5].map(i => parseInt(h.slice(i, i + 2), 16) / 255).map(x => x <= 0.03928 ? x / 12.92 : ((x + 0.055) / 1.055) ** 2.4); return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]; };
  const cr = (a, b) => { const [x, y] = [L(a), L(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };
  return ["light", "dark"].map(t => { document.documentElement.dataset.theme = t; return [1, 2, 3, 4].filter(i => cr(v(`--chart-${i}`), v("--panel")) < 3).join(",") || "ok"; }).join("|")'
ck "every chart series token reaches 3:1 on the panel, light and dark" "ok|ok" "$(bash "$p" '#overview' --fixture "$O" --width 1280 --probe "$cc")"
exit $fail
