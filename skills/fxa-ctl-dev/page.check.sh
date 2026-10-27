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
  AGENTS = null; ERRS = []; renderSide(); const a = document.querySelector(".side .empty")?.textContent;
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
ck "page.sh says why Chrome failed, in place of an empty answer" "chrome exit" "$(CHROME=/usr/bin/false bash "$p" '#teams' --probe 'return 1' 2>&1 | cut -c1-11)"
# Chrome that prints the whole page, then exits 2 at teardown (the GitHub macOS runner): the answer counts.
printf '#!/bin/sh\necho "<html><body><pre id=\\"__probe\\">late exit</pre></body></html>"\nexit 2\n' > "${c2:=$(mktemp -d)/chrome2}"; chmod +x "$c2"
ck "a Chrome that exits 2 after a complete page still gives the probe result" "late exit" "$(CHROME="$c2" bash "$p" '#teams' --probe 'return 1' 2>&1)"
exit $fail
