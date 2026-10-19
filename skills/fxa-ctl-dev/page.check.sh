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
ck "belts at 1280 px: the status has its full text and overlaps nothing" "true|true" "$(bash "$p" '#pipeline/belts' --fixture "$F" --width 1280 --probe '
  const a = document.querySelector(".belt[data-belt=\"FXA-1\"] > a"), r = x => a.querySelector(x).getBoundingClientRect(), st = r(".st");
  return `${/approve the tooling change/.test(a.querySelector(".st .l2").title)}|${st.left >= r(".trk").right && st.right <= r(".age").left && a.scrollWidth <= a.clientWidth}`')"
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
# The whole flow on one fixture, at desktop and phone width: no section fails, nothing scrolls sideways.
flow='const w = () => new Promise(r => setTimeout(r, 250)), bad = () => [...document.querySelectorAll(".emptybox")].some(e => /did not render/.test(e.textContent)), wide = () => document.documentElement.scrollWidth > innerWidth;
  let fails = [];
  const step = (n, ok) => { if (!ok || bad() || wide()) fails.push(n); };
  location.hash = "#pipeline"; await w(); step("open", /agents? works? now/.test(document.querySelector(".bhead")?.textContent ?? "") && document.querySelectorAll("#s-lanes h2").length === 4);
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
sbw='const w = () => new Promise(r => setTimeout(r, 300)); await w(); const L = () => document.getElementById("sb-list"), H = () => document.getElementById("sb-head").textContent.trim(), N = () => document.getElementById("n-runners");
  const codes = () => [...L().querySelectorAll("code")].map(c => c.textContent), inBtn = () => [...L().querySelectorAll("button code, button .steps")].length;'
ck "Sandboxes: the chip equals the floor, live rows then 'Needs a fix · 3', commands in <code> outside the buttons, the badge" "2 of 5 pipeline sandboxes in use, plus 1 Slack session and 1 scheduled run|true|EX-101,EX-102,agent-ex0001,Nightly review,agent-ex0003|Needs a fix · 3|fxa-sandbox-ctl stop agent-ex0004;fxa-sandbox-ctl stop agent-41c0e6|0|true|3|3 sandboxes need a fix|true" "$(bash "$p" '#runners' --fixture "$B" --width 1280 --probe "$sbw"'
  render(); const live = [...L().querySelectorAll("ul.sbl")[0].querySelectorAll("button")].map(b => b.textContent.replace(/^(Pipeline|Slack) /, ""));
  return [H(), H() === floorHead(ovFloor()) && sbRows().live[0].max_seconds === 5400 && sbRows().live[0].usd === 1.25, live.join(","), L().querySelector("h3.sbh").textContent, codes().join(";"), inBtn(), /ex-auto-4 is not free for a launch\. Its last ticket EX-130 is not in flight/.test(L().textContent) && /fxa-sandbox-ctl slots/.test(L().textContent),
    N().textContent, N().getAttribute("aria-label"), /ex-auto-3 · held for a run in flight: ex-auto-5 \(EX-103\) · 2 session slots/.test(L().textContent)].join("|")')"
ck "Sandboxes as a non-admin: no routine name, no routine link, the Routines tab says why" "2 of 5 pipeline sandboxes in use, plus 2 sessions|false|true|false|Only a team admin can see routine runs." "$(bash "$p" '#runners' --fixture "$B" --width 1280 --probe "$sbw"'
  TEAM_ADMIN = { admin: false }; render(); const t = L().innerHTML;
  const r = [H(), /Nightly review/.test(t + document.getElementById("sb-head").innerHTML), /Routine · scheduled run/.test(t), /href=/.test(t)];
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
ck "Sandboxes review: a stopped session with an unsafe key gets no command, and nothing says 'stop null'" "false|false" "$(bash "$p" '#runners' --fixture "$B" --width 1280 --probe "$sbw"'
  AGENTS.sessions[3].key = "x;rm -rf ~"; AGENTS.instances.push({ name: "agent-x;rm -rf ~", state: "running", age_seconds: 9000, where: "gce" }); render();
  return [codes().some(c => /rm -rf/.test(c)), /stop null/.test(L().textContent)].join("|")')"
ck "Sandboxes review: a non-admin sees no request, routine name or cost of a stopped routine session with a runner left" "true|false|false|false" "$(bash "$p" '#runners' --fixture "$B" --width 1280 --probe "$sbw"'
  Object.assign(AGENTS.sessions[3], { routine_run: 7, routine_name: "Secret weekly", cost: 9.87, summary: JSON.stringify({ cost: 9.87 }) }); TEAM_ADMIN = { admin: false }; render(); const t = L().textContent;
  return [/Routine · scheduled run/.test(t), /another sample question/.test(t), /Secret weekly/.test(t), /9\.87/.test(t)].join("|")')"
ck "Sandboxes: a normal stop is 'stopping' with no command; 10 min later it is a fix row" "stopping|false|true|4" "$(bash "$p" '#runners' --fixture "$B" --width 1280 --probe "$sbw"'
  const st = () => [...L().querySelectorAll("li")].find(li => li.querySelector("[data-sbsel=\"sess:agent-ex0003\"], [data-sbsel=\"fix:agent-agent-ex0003\"]"));
  const a = st().querySelector(".f:nth-of-type(2)")?.textContent.replace(/^Now: /, ""), b = codes().includes("fxa-sandbox-ctl stop agent-ex0003");
  AGENTS.sessions[2].stopped_at = Date.now() / 1000 - 700; render();
  return [a, b, codes().includes("fxa-sandbox-ctl stop agent-ex0003"), N().textContent].join("|")')"
ck "Sandboxes: a stale feed shows the rows with a warning, no command, '? in use' and badge '?'" "? in use|true|0|?|Sandbox fixes unknown: the agents feed could not be read" "$(bash "$p" '#runners' --fixture "$B" --width 1280 --probe "$sbw"'
  STATE.agents_age_seconds = 600; render(); return [H(), /The agents feed is 10 min old: these rows may be out of date\./.test(L().textContent), codes().length, N().textContent, N().getAttribute("aria-label")].join("|")')"
ck "Sandboxes: a held slot names a ticket only when it is one, and an old snapshot is not checked yet" "true|true|?|false" "$(bash "$p" '#runners' --fixture "$B" --width 1280 --probe "$sbw"'
  AGENTS.pool[3] = { ...AGENTS.pool[3], key: "HEAD", branch: "HEAD" }; render(); const a = /ex-auto-4 is not free for a launch \(branch HEAD\)/.test(L().textContent);
  AGENTS.pool[3] = { ...AGENTS.pool[3], key: "EX-130", branch: "ex-130" }; SNAP.generated_at = new Date(Date.parse(AGENTS.generated_at) - 9999e3).toISOString(); render();
  return [a, /ex-auto-4 held by EX-130 · in flight not checked yet/.test(L().textContent), N().textContent, /Its last ticket EX-130/.test(L().textContent)].join("|")')"
ck "Sandboxes: the tabs filter the list" "EX-101,EX-102,agent-agent-41c0e6,EX-130|agent-ex0001,agent-ex0003,agent-ex0004|Nightly review" "$(bash "$p" '#runners/pipeline' --fixture "$B" --width 1280 --probe "$sbw"'
  render(); const keys = () => [...L().querySelectorAll("[data-sbsel]")].map(b => b.textContent.replace(/^(Pipeline|Slack) /, "")).join(",");
  const a = keys(); location.hash = "#runners/slack"; await w(); const b = keys(); location.hash = "#runners/routines"; await w(); return [a, b, keys()].join("|")')"
ck "Sandboxes: nothing runs; nothing set up; the feed failed" "No sandbox runs now.|No sandbox in use|true|No sandbox slot is set up, and no Slack session is live.|Sandboxes unknown: the agents feed could not be read.|? in use|?" "$(bash "$p" '#runners' --fixture "$B" --width 1280 --probe "$sbw"'
  AGENTS.runners = []; AGENTS.sessions = []; AGENTS.instances = []; AGENTS.pool = AGENTS.pool.map(x => ({ ...x, agent: null, busy: false, key: null })); AGENTS.free_slots = AGENTS.pool.map(x => x.slot); render();
  const a = [L().querySelector(".emptybox")?.textContent, H(), N().textContent === "" && !N().hasAttribute("aria-label")];
  AGENTS.pool = []; AGENTS.free_slots = []; render(); const b = L().querySelector(".emptybox")?.textContent;
  STATE.agents_error = "boom"; render(); return [...a, b, L().textContent.trim(), H(), N().textContent].join("|")')"
ck "Sandboxes: one part that throws leaves the chip and the badge" "true|2 of 5 pipeline sandboxes in use, plus 1 Slack session and 1 scheduled run|3" "$(bash "$p" '#runners' --fixture "$B" --width 1280 --probe "$sbw"'
  renderSbList = () => { throw new Error("boom"); }; render(); return [/This section did not render: boom\./.test(L().textContent), H(), N().textContent].join("|")')"
ck "Sandboxes recheck: a stale feed keeps its rows but no 'No sandbox runs now.' and no free line; a stray on a slot's agent is unknown; a failed slot read; a null SNAP keeps the chip" "true|false|false|true|true|true|false|true" "$(bash "$p" '#runners' --fixture "$B" --width 1280 --probe "$sbw"'
  STATE.agents_age_seconds = 600; render(); const st = [L().querySelectorAll("ul.sbl li").length > 0, /No sandbox runs now/.test(L().textContent), !!L().querySelector(".sbfree")];
  STATE.agents_age_seconds = 12; AGENTS.instances.push({ name: "agent-ex-109", state: "running", age_seconds: 900, where: "gce" }); AGENTS.pool[2] = { ...AGENTS.pool[2], agent: "ex-109", busy: true }; render();
  const u = /agent-ex-109: the slot says it runs, but the agents feed has no run row/.test(L().textContent) && !codes().includes("fxa-sandbox-ctl stop ex-109");
  AGENTS.free_slots = null; render(); const sl = /ex-auto-4: slots unknown: the slot read failed/.test(L().textContent) && !/Its last ticket EX-130/.test(L().textContent);
  AGENTS.free_slots = ["ex-auto-3"]; AGENTS.pool[2] = { ...AGENTS.pool[2], agent: null, busy: false }; AGENTS.instances.pop(); SNAP = null; render();
  return [...st, u, sl, !/\?/.test(H()), /\/home|\/Users|worktree path/.test(L().textContent), H() === floorHead(ovFloor())].join("|")')"
ck "Sandboxes at 390 and 1280 px: no sideways scroll, no side list" "true|true|true" "$(bash "$p" '#runners' --fixture "$B" --width 390 --probe "$sbw"'render(); return document.documentElement.scrollWidth <= innerWidth')|$(bash "$p" '#runners' --fixture "$B" --width 1280 --probe "$sbw"'render(); return document.documentElement.scrollWidth <= innerWidth')|$(bash "$p" '#runners' --fixture "$B" --width 1280 --probe "$sbw"'return getComputedStyle(document.getElementById("side")).visibility === "hidden"')"
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
ck "Merged and Cost cards: Stats number, no 0 for an unread or old list, focus kept, a throw stops nothing" "2|\$1.50|—|true|true|true" "$(bash "$p" '#overview' --fixture "$F" --width 1280 --probe '
  const now = Date.now(), iso = d => new Date(now - d * 86400000).toISOString(), card = k => document.querySelector(`#ov-mini [data-focus="${k}"]`);
  STATS = { prs: [{ n: 1, merged: iso(1) }, { n: 2, merged: iso(2) }, { n: 3, merged: iso(20) }], prs_at: Math.round(now / 1000) - 60, rows: [{ at: iso(1), usd: 2 }, { at: iso(3), usd: 1 }, { at: iso(30), usd: 50 }] };
  renderOvMini(); const m = card("ov-merged").querySelector(".big").textContent, c = card("ov-cost").querySelector(".big").textContent;
  const same = c === usd(costPerMerged(now - 7 * 86400000, now, STATS.prs, STATS.rows).per);
  // A value outside the links changes, so the card is rewritten: the focus must come back to the same link.
  card("ov-cost").focus(); const n0 = card("ov-cost"); STATS = { ...STATS, rows: [...STATS.rows, { at: iso(0.1), usd: 4 }] }; render();
  const kept = document.activeElement?.dataset.focus === "ov-cost" && document.activeElement !== n0 && /\$3\.50/.test(card("ov-cost").textContent);
  STATS = { ...STATS, prs: null }; renderOvMini(); const none = card("ov-merged").querySelector(".big").textContent;
  STATS = { ...STATS, prs: [], prs_at: Math.round(now / 1000) - 7200 }; renderOvMini(); const old = /old/.test(card("ov-cost").textContent) && !/\$0\.00/.test(card("ov-cost").textContent);
  const nav = renderNav; renderNav = () => { throw new Error("boom"); }; document.title = "x"; render(); renderNav = nav;
  return [m, c, none, same && kept, old, document.title !== "x"].join("|")')"
ck "Stats PRs renders with a PR merged this week and a run in it" "true|false" "$(bash "$p" '#stats/prs' --fixture "$F" --width 1280 --probe '
  const now = Date.now(), iso = d => new Date(now - d * 86400000).toISOString();
  STATS = { ...(STATS ?? {}), prs: [{ n: 1, key: "FXA-1", title: "t", state: "MERGED", created: iso(2), merged: iso(1), add: 1, del: 0, src: "pipeline" }], rows: [{ at: iso(1), usd: 2, src: "pipeline", key: "FXA-1" }], llm: STATS?.llm ?? {} };
  renderStats(); const t = document.body.innerText; return [/Cost per merged PR/.test(t), /did not render|is not defined/.test(t)].join("|")')"
# Spend and Today (ov-spend slice). Rows over 100 days in four sources, one 95 days ago; a peak day with 3 merged PRs.
SP='const DAY = 86400000, noon = d => { const t = new Date(); t.setHours(12, 0, 0, 0); return new Date(t.getTime() - d * DAY).toISOString(); };
  const rows = []; for (let d = 0; d < 100; d++) [["pipeline", 1], ["pass", 0.5], ["slack", 0.25], ["answer", 0.125]].forEach(([src, u]) => rows.push({ at: noon(d), src, usd: d === 4 ? u * 20 : u, key: `K-${d}-${src}`, model: "claude-opus-5-5" }));
  rows.push({ at: noon(95), src: "pipeline", usd: 1000, key: "OLD-1" });
  STATS = { rows, prs: [1, 2, 3].map(n => ({ n, merged: noon(4), src: "pipeline" })), prs_at: Math.round(Date.now() / 1000) - 60, llm: { hour_usd: 0.42 } }; STATS_ERR = null;
  const statsSpend = r => { SF = { ...SF_DEFAULT, range: r }; STATS_TAB = "spend"; LAST["s-stats"] = ""; renderStats(); return [...document.querySelectorAll("#s-stats .scard")].find(c => c.querySelector(".lbl").textContent === "Spend").querySelector(".v").textContent; };'
ck "Spend: equals Stats for 7, 30 and 90 days; sources add up; the 95-day row is out of 90d; the peak names 3 merged PRs" "true|true|true|true" "$(bash "$p" '#overview' --fixture "$F" --width 1280 --probe "$SP"'
  const eq = ["7d", "30d", "90d"].every(r => usd(ovSpend(r).total) === statsSpend(r));
  const sp = ovSpend("90d"), parts = Object.values(sp.by).reduce((a, b) => a + b, 0);
  OV_RANGE = "30d"; renderOvSpend(); const t = document.querySelector("#ov-spend").textContent;
  return [eq, Math.abs(parts - sp.total) < 1e-9, sp.total < 1000, /3 PRs merged that day/.test(t)].join("|")')"
ck "Today: the usual day, the last hour and midnight; 0 is \$0.00; 2 days of history is gray; a stale feed is unknown" "true|true|true|true" "$(bash "$p" '#overview' --fixture "$F" --width 1280 --probe "$SP"'
  renderOvToday(); const t1 = document.querySelector("#ov-today").textContent;
  const a = /Usual day \$1\.88/.test(t1) && /100% of a usual day/.test(t1) && /LLM, last hour \$0\.42/.test(t1) && /By midnight about \$\d+/.test(t1) && /Opus 5\.5 \$1\.88/.test(t1);
  STATS = { ...STATS, llm: { hour_usd: 0 } }; renderOvToday(); const b = /LLM, last hour \$0\.00/.test(document.querySelector("#ov-today").textContent);
  STATS = { ...STATS, rows: STATS.rows.filter(r => Date.now() - Date.parse(r.at) < 2.5 * DAY) }; renderOvToday(); const c = /not enough history for a usual day/.test(document.querySelector("#ov-today").textContent);
  STATE.stats_age_seconds = 420; STATE.stats_interval = 60; renderOvToday(); const d = /LLM, last hour unknown: The stats feed is 7 min old/.test(document.querySelector("#ov-today").textContent);
  return [a, b, c, d].join("|")')"
ck "A failed stats read: the cards say so, show no \$0.00, keep the last figures; a throwing card leaves the others" "true|true|true" "$(bash "$p" '#overview' --fixture "$F" --width 1280 --probe "$SP"'
  const w = () => new Promise(r => setTimeout(r, 50)), f0 = window.fetch;
  STATS = null; window.fetch = async u => String(u).includes("/api/stats") ? new Response("not json", { status: 502 }) : f0(u); STATS_AT = 0; await loadStats(); await w();
  const a = /could not be read/.test(document.querySelector("#ov-spend").textContent) && !/\$0\.00/.test(document.querySelector("#ov-spend").textContent + document.querySelector("#ov-today").textContent);
  window.fetch = f0; { '"$SP"' } const keep = STATS; STATS_AT = 0; window.fetch = async u => String(u).includes("/api/stats") ? new Response("{}", { status: 500 }) : f0(u); await loadStats(); window.fetch = f0;
  const b = STATS === keep && /These figures are from/.test(document.querySelector("#ov-spend").textContent);
  const sp = renderOvSpend; renderOvSpend = () => { throw new Error("boom"); }; STATS_ERR = null; STATS_AT = 0; window.fetch = async u => String(u).includes("/api/stats") ? new Response(JSON.stringify(keep)) : f0(u);
  await loadStats(); window.fetch = f0; renderOvSpend = sp;
  return [a, b, /did not render: boom/.test(document.querySelector("#ov-spend").textContent) && /Today/.test(document.querySelector("#ov-today").textContent)].join("|")')"
ck "A spend link sets Stats for the visit: totals agree, no Stats click saves, a bad value does nothing, Restore and Keep these" "true|true|true|true|true" "$(bash "$p" '#overview' --fixture "$F" --width 1280 --probe "$SP"'
  const w = () => new Promise(r => setTimeout(r, 100)); localStorage.setItem("statsFilter", JSON.stringify({ ...SF_DEFAULT, model: "m1" })); SF = { ...SF_DEFAULT, model: "m1" }; SF_FROM_OV = false;
  OV_RANGE = "7d"; renderOvSpend(); const tot = document.querySelector("#ov-spend .tot").textContent; document.querySelector("#ov-spend .tot").click(); await w();
  const a = location.hash === "#stats/spend" && SF.range === "7d" && SF.model === "all" && statsSpend("7d") === tot && !!document.querySelector("#s-stats .sfov");
  SF_FROM_OV = true; setStatsFilter({ range: "30d" }); const b = JSON.parse(localStorage.getItem("statsFilter")).model === "m1";
  const x = document.createElement("a"); x.dataset.sfrange = "x;y"; document.body.appendChild(x); const before = SF.range; x.click(); const c = SF.range === before;
  document.querySelector("[data-sfrestore]").click(); const d = SF.model === "m1" && !SF_FROM_OV;
  SF_FROM_OV = true; setStatsFilter({ range: "90d" }, false); document.querySelector("[data-sfkeep]").click(); const e = JSON.parse(localStorage.getItem("statsFilter")).range === "90d" && !SF_FROM_OV;
  return [a, b, c, d, e].join("|")')"
# Daylight saving (New York): with a fixed date after each change, Spend still equals Stats and Today finds all 30 days.
DST='const FIX = __T__, R = Date; class D extends R { constructor(...a) { super(...(a.length ? a : [FIX])); } static now() { return FIX; } } window.Date = D;
  const DAY = 86400000, rows = []; for (let i = 0; i < 100; i++) { const d = new R(FIX); d.setDate(d.getDate() - i); d.setHours(12, 0, 0, 0); rows.push({ at: d.toISOString(), src: "pipeline", usd: 1, key: "K" + i }); }
  STATS = { rows, prs: [], prs_at: null, llm: {} }; STATS_ERR = null;
  const statsSpend = r => { SF = { ...SF_DEFAULT, range: r }; STATS_TAB = "spend"; LAST["s-stats"] = ""; renderStats(); return [...document.querySelectorAll("#s-stats .scard")].find(c => c.querySelector(".lbl").textContent === "Spend").querySelector(".v").textContent; };
  const eq = ["7d", "30d", "90d"].every(r => usd(ovSpend(r).total) === statsSpend(r)); renderOvToday();
  return [eq, /100% of a usual day/.test(document.querySelector("#ov-today").textContent)].join("|")'
for t in 'new Date(2027, 2, 20, 12).getTime()' 'new Date(2026, 10, 3, 12).getTime()'; do
  ck "daylight saving: Spend equals Stats and Today sees 30 days ($t)" "true|true" "$(TZ=America/New_York bash "$p" '#overview' --fixture "$F" --width 1280 --probe "${DST/__T__/$t}")"
done
ck "The range buttons repaint after a click, a legend link sets the source, an old PR list hides the merged count, a 200 error body keeps the figures" "true|true|true|true" "$(bash "$p" '#overview' --fixture "$F" --width 1280 --probe "$SP"'
  const w = () => new Promise(r => setTimeout(r, 100)); render(); const b7 = document.querySelector("[data-ovrange=\"7d\"]"); b7.focus(); b7.click(); await w();
  const a = document.querySelector("[data-ovrange=\"7d\"]").getAttribute("aria-pressed") === "true" && document.querySelector("[data-ovrange=\"30d\"]").getAttribute("aria-pressed") === "false";
  document.querySelector("#ov-spend [data-sfsrc=\"slack\"]").click(); await w(); const b = SF.src === "slack" && SF.range === "7d"; location.hash = "#overview"; await w();
  STATS = { ...STATS, prs_at: Math.round(Date.now() / 1000) - 7200 }; OV_RANGE = "30d"; renderOvSpend(); const c = !/merged that day/.test(document.querySelector("#ov-spend").textContent);
  const keep = STATS, f0 = window.fetch; STATS_AT = 0; window.fetch = async u => String(u).includes("/api/stats") ? new Response(JSON.stringify({ error: "stats unavailable" })) : f0(u); await loadStats(); window.fetch = f0;
  return [a, b, c, STATS === keep && /could not be read \(stats unavailable\)/.test(document.querySelector("#ov-spend").textContent)].join("|")')"
# The floor (ov-floor slice): 7 slots with FXA-1 at Agent (idle 700 s), FXA-2 booting, FXA-3 stalled and 4 free; a live
# Slack session with 8 turns; a routine run that waits on its owner; a viewer who is not a team admin.
FL='SNAP.inflight = [{ key: "FXA-1", summary: "one" }, { key: "FXA-2", summary: "two" }, { key: "FXA-3", summary: "three" }];
  AGENTS.runners = [{ key: "FXA-1", name: "fxa-auto-1", agent_alive: true, stage: "watching", elapsed_seconds: 900, agent: { idle_seconds: 700, cost_so_far: 1.5 } },
    { key: "FXA-2", name: "fxa-auto-2", agent_alive: true, stage: "starting", elapsed_seconds: 60, agent: {} },
    { key: "FXA-3", name: "fxa-auto-3", agent_alive: false, stage: "stalled", detail: "no-motion 30m", elapsed_seconds: 4000, agent: {} }];
  AGENTS.pool = [1, 2, 3, 4, 5, 6, 7].map(n => ({ slot: `fxa-auto-${n}`, agent: n < 4 ? `fxa-auto-${n}` : null, key: n < 4 ? `FXA-${n}` : "HEAD", busy: n < 4 }));
  AGENTS.free_slots = ["fxa-auto-4", "fxa-auto-5", "fxa-auto-6", "fxa-auto-7"];
  AGENTS.sessions = [{ key: "agent-abc123", state: "active", agent_alive: true, turns: 8, created: Date.now() / 1000 - 600, owner: "U1", request: "fix the thing" },
    { key: "agent-rt0001", state: "active", agent_alive: false, routine_run: 4, routine_name: "Nightly", request: "SECRET ROUTINE PROMPT", created: Date.now() / 1000 - 60, owner: "U2" }];
  AGENTS.instances = []; TEAM_ADMIN = { admin: false }; STATE.agents_error = null; render();
  const ft = k => [...document.querySelectorAll("#ov-floor .ft")].find(e => e.textContent.includes(k));'
ck "floor: stops from the belts, the header, the chip, the routine tile for a non-admin, the free slots" "true|true|true|true|true|true" "$(bash "$p" '#overview' --fixture "$F" --width 1280 --probe "$FL"'
  const h = document.querySelector("#ov-floor h2 .note").textContent, a1 = ft("FXA-1").querySelector("a");
  const a = h === "3 of 7 pipeline sandboxes in use (1 stalled), plus 2 sessions (1 waits on its owner)";
  const b = a1.getAttribute("aria-label") === "FXA-1, Stop 3 of 9, Agent" && a1.getAttribute("href") === "#pipeline/belts/FXA-1" && /idle 11 min/.test(ft("FXA-1").textContent) && /Stop 2 of 9, Boot/.test(ft("FXA-2").textContent);
  const c = ft("FXA-3").classList.contains("bad") && /stalled/.test(ft("FXA-3").textContent) && /4 free: fxa-auto-4, 5, 6, 7/.test(document.querySelector("#ov-floor .ovfree").textContent) && !document.querySelector("#ov-floor .ft.free");
  const s1 = ft("agent-abc123"), r = ft("scheduled run");
  const d = /turn 8/.test(s1.textContent) && s1.querySelector("a").getAttribute("href") === "#sessions/live/agent-abc123" && !r.querySelector("a") && !/Nightly|SECRET/.test(document.getElementById("ov-floor").innerHTML) && /waits on its owner/.test(r.textContent) && !/U2/.test(r.textContent);
  const e = document.querySelector(".ovchip").textContent.startsWith("3 at work now");
  TEAM_ADMIN = { admin: true }; render(); const f = /plus 1 Slack session and 1 scheduled run/.test(document.querySelector("#ov-floor h2 .note").textContent);
  return [a, b, c, d, e, f].join("|")')"
ck "floor: bad keys get no link, the last output line shows escaped and outside the link, focus and its name survive a poll, an unknown feed is ?" "true|true|true|true" "$(bash "$p" '#overview' --fixture "$F" --width 1280 --probe "$FL"'
  AGENTS.runners[0].agent.last_tool = "curl -H \"Authorization: Bearer fxm_<masked>\" <img src=x>"; AGENTS.runners.push({ key: "x\"><b>", name: "fxa-auto-9", agent_alive: true, stage: "watching", agent: {} });
  AGENTS.sessions.push({ key: "javascript:alert(1)", state: "active", agent_alive: true, request: "x" }); render();
  const a = !!ft("x\"><b>") && !ft("x\"><b>").querySelector("a") && !document.querySelector("#ov-floor b") && !/javascript:/.test([...document.querySelectorAll("#ov-floor a")].map(x => x.getAttribute("href")).join(" ")) && /Bearer fxm_<masked>/.test(ft("FXA-1").querySelector(".ftl").textContent) && !document.querySelector("#ov-floor img") && !ft("FXA-1").querySelector("a").contains(ft("FXA-1").querySelector(".ftl"));
  const l = () => ft("FXA-1").querySelector("a"); l().focus(); const n0 = l(); AGENTS.runners[0].agent.cost_so_far = 9; render(); const b = document.activeElement === n0 && n0.getAttribute("aria-label") === "FXA-1, Stop 3 of 9, Agent";
  AGENTS.sessions.push({ key: "agent-new001", state: "active", agent_alive: true, request: "y" }); render(); const c = document.activeElement?.dataset.focus === "ft-FXA-1" && !!ft("agent-new001");
  STATE.agents_error = "agents failed"; render(); const d = /^\? at work now/.test(document.querySelector(".ovchip").textContent) && /Sandboxes unknown: the agents feed could not be read/.test(document.getElementById("ov-floor").textContent) && !document.querySelector("#ov-floor .ft.free");
  return [a, b, c, d].join("|")')"
ck "floor: a throwing card leaves the others, and Running now is gone" "true|true" "$(bash "$p" '#overview' --fixture "$F" --width 1280 --probe '
  const f = renderOvFloor; renderOvFloor = () => { throw new Error("boom"); }; LAST["ov-floor"] = ""; render(); renderOvFloor = f;
  return [/This section did not render: boom/.test(document.getElementById("ov-floor").textContent) && !!document.querySelector("#ov-mini .big") && !!document.querySelector("#ov-head .seg"),
    !document.getElementById("s-running") && !/Running now/.test(document.getElementById("main").innerText) && typeof renderRunning === "undefined"].join("|")')"
ck "floor: held and unknown slots, a failed run and an exited agent, the chip's LLM hour, a fault repaints under focus" "true|true|true|true|true" "$(bash "$p" '#overview' --fixture "$F" --width 1280 --probe "$FL"'
  AGENTS.free_slots = ["fxa-auto-4"]; render(); const a = /held: fxa-auto-5, 6, 7/.test(document.getElementById("ov-floor").textContent) && /1 free: fxa-auto-4/.test(document.getElementById("ov-floor").textContent);
  AGENTS.free_slots = null; render(); const b = /slots unknown: fxa-auto-4, 5, 6, 7/.test(document.getElementById("ov-floor").textContent) && !/\d free:/.test(document.getElementById("ov-floor").textContent);
  AGENTS.free_slots = ["fxa-auto-4", "fxa-auto-5", "fxa-auto-6", "fxa-auto-7"]; AGENTS.runners[1].stage = "error"; AGENTS.runners[0] = { ...AGENTS.runners[0], agent_alive: false, handoff: false }; render();
  const c = /run failed/.test(ft("FXA-2").textContent) && ft("FXA-2").classList.contains("bad") && /agent exited/.test(ft("FXA-1").textContent);
  STATS = { rows: [], prs: [], llm: { hour_usd: 0.42 } }; STATS_ERR = null; render(); const d = /at work now · LLM \$0\.42 in the last hour/.test(document.querySelector(".ovchip").textContent);
  AGENTS.runners[0] = { ...AGENTS.runners[0], agent_alive: true, stage: "watching" }; AGENTS.runners[1].stage = "watching"; render();
  ft("FXA-1").querySelector("a").focus(); AGENTS.runners[1].stage = "stalled"; render();
  const e = ft("FXA-2").classList.contains("bad") && /\(2 stalled\)/.test(document.querySelector("#ov-floor h2 .note").textContent) && document.activeElement?.dataset.focus === "ft-FXA-1";
  return [a, b, c, d, e].join("|")')"
# What the system is doing (ov-system slice), with a fixed date in New York.
SYS='const FIX = __T__, R = Date; class D extends R { constructor(...a) { super(...(a.length ? a : [FIX])); } static now() { return FIX; } } window.Date = D;
  const now = Math.round(FIX / 1000), at = (h, m, dd = 0) => { const d = new R(FIX); d.setDate(d.getDate() + dd); d.setHours(h, m, 0, 0); return Math.round(d.getTime() / 1000); };
  const pt = []; for (let m = 0; at(15, 4) + m * 60 <= at(19, 59); m += 5) pt.push(at(15, 4) + m * 60); pt.splice(3, 1);
  SNAP.health = { ...SNAP.health, lock_age_seconds: 40, lock_stale_seconds: 1800, pass_timer: "on", paused: null, pass_times: [now - 60, ...pt, ...__NEXT__] };
  SNAP.review = Array.from({ length: 6 }, (_, i) => ({ key: `FXA-${70 + i}`, pr: 70 + i, state: "OPEN", ok: 20, fail: 0, running: 0, created: new R(FIX - (12 - i) * 86400000).toISOString() }));
  SNAP.repo = SNAP.team.repo = "example/app";
  SNAP.inflight = [{ key: "FXA-60", stage: "pr", pr: 77, ok: 18, fail: 0, running: 4 }, { key: "FXA-61", stage: "pr", pr: "5\"><img src=x>", ok: 1, fail: 0, running: 1 }]; AGENTS.runners = [];
  AGENTS.sessions = [{ key: "agent-rt0002", state: "active", agent_alive: true, routine_run: 5, routine_name: "Live one", created: now - 60, request: "r" }];
  SNAP.queue = { ...(SNAP.queue ?? {}), ready: Array.from({ length: 27 }, (_, i) => ({ key: `FXA-${i + 1}` })) };
  STATE.age_seconds = 44; STATE.interval = 120; STATE.agents_age_seconds = 18;
  RTSUM = { teams: {}, routines: { 1: { name: "Nightly <img src=x> report", team: "fxa", next: at(2, 0, 1), runs_30d: 10, cost_30d: 30 }, 2: { name: "Odd team", team: "../x", next: at(16, 0) }, 3: { name: "Old", team: "fxa", next: now - 30 } } }; RTSUM_ERR = ""; RTSUM_AT = Date.now();
  const txt = () => document.getElementById("ov-sys").innerText, html = () => document.getElementById("ov-sys").innerHTML;'
WED='new Date(2026, 9, 21, 15, 0).getTime()'; FRI='new Date(2026, 9, 23, 15, 0).getTime()'
ck "system: Wednesday 15:00 reads the real facts; an admin sees the routine, escaped; a non-admin sees none" "true|true|true|true|true|true" "$(TZ=America/New_York bash "$p" '#overview' --fixture "$F" --width 1280 --probe "$(printf '%s' "$SYS" | sed "s/__T__/$WED/; s/__NEXT__/[at(7, 4, 1)]/")"'
  TEAM_ADMIN = { admin: true }; render(); const t = txt(), h = html();
  const a = /Pipeline pass · runs now · 40s/.test(t) && /checks 18 of 22 done/.test(t) && /width:82%/.test(h) && /href="https:\/\/github\.com\/example\/app\/pull\/77\/checks"/.test(h);
  const b = /Merge watch · 6 PRs wait on a human review · the oldest is 12 days/.test(t);
  const c = /3:04 PM Pipeline pass, then every 5 min until 7:59 PM/.test(t) && /Quiet hours start 7:59 PM/.test(t) && /First pass of the day 7:04 AM · 27 tickets are ready/.test(t);
  const a2 = /checks 1 of 2 done/.test(t) && !/pull\/5/.test(h) && !document.querySelector("#ov-sys img") && /Routine Live one runs now/.test(t);
  const d = /then every 5 min/.test(t) && document.querySelectorAll("#ov-sys svg line").length === 59 && document.querySelectorAll("#ov-sys svg rect").length === 1 && document.querySelectorAll("#ov-sys svg circle").length === 2;
  const e = /2:00 AM Routine Nightly <img src=x> report · about \$3\.00/.test(t) && !document.querySelector("#ov-sys img") && !/Routine Old/.test(t) && /4:00 PM Routine Odd team/.test(t) && !/#teams\/\.\.\/x/.test(h);
  TEAM_ADMIN = { admin: false }; render(); const f = !/Nightly|Odd team|Live one|routine run|circle/.test(html().replace("Team admins see the routine runs here.", "")) && /Team admins see the routine runs here\./.test(txt());
  return [a && a2, b, c, d, e, f].join("|")')"
ck "system: Friday afternoon names the weekday of the first pass" "true" "$(TZ=America/New_York bash "$p" '#overview' --fixture "$F" --width 1280 --probe "$(printf '%s' "$SYS" | sed "s/__T__/$FRI/; s/__NEXT__/[at(7, 4, 1), at(8, 4, 1)]/")"'
  TEAM_ADMIN = { admin: false }; render(); return /First pass of the day Sat 7:04 AM/.test(txt()) && /Quiet hours start 7:59 PM/.test(txt())')"
ck "system: it says when it cannot tell, and shows no false time" "true|true|true|true|true|true|true" "$(TZ=America/New_York bash "$p" '#overview' --fixture "$F" --width 1280 --probe "$(printf '%s' "$SYS" | sed "s/__T__/$WED/; s/__NEXT__/[]/")"'
  const st = (patch, f) => { Object.assign(SNAP.health, patch); render(); return f(txt()); };
  TEAM_ADMIN = { admin: true };
  const a = st({ pass_times: null, next_pass_epoch: now + 600 }, t => /Pass times unknown on this host\./.test(t) && /3:10 PM Next pipeline pass/.test(t) && !document.querySelector("#ov-sys svg line"));
  const b = st({ pass_timer: "off", lock_age_seconds: null }, t => /The pass timer is off, so no pass runs\./.test(t));
  const c = st({ pass_timer: "on", lock_age_seconds: 4000 }, t => /A pass lock is 67 min old/.test(t));
  const d = st({ paused: "deploy" }, t => /Passes are paused: deploy/.test(t));
  SNAP.review = null; const e = st({}, t => /CI watch and Merge watch: unknown, GitHub fetch failed/.test(t) && !/checks 18/.test(t));
  RTSUM_AT = Date.now() - 50000; const f = st({}, t => /Routine times unknown: the routine store cannot be read/.test(t) && !/2:00 AM/.test(t));
  STATE.age_seconds = 900; const g = st({ pass_times: [now + 300], paused: null, lock_age_seconds: 40 }, t => /Pass times unknown: the snapshot is 15 min old/.test(t) && !document.querySelector("#ov-sys svg line")
    && /Pass, CI and merge watch unknown: the snapshot is 15 min old/.test(t) && !/Pipeline pass · runs now|Merge watch · /.test(t) && /--bad/.test(document.querySelector("#ov-sys .row[style*=\"--bad\"]")?.getAttribute("style") ?? ""));
  return [a, b, c, d, e, f, g].join("|")')"
# The Overview fixture (sample data only, times relative to the run): every card renders, none errors.
O="$(dirname "$0")/page-fixture-overview.json"
ck "overview fixture: every card heading, no section error, relative times read as recent" "true|true|true" "$(bash "$p" '#overview' --fixture "$O" --width 1280 --probe '
  const hs = ["ov-spend", "ov-today", "ov-floor", "ov-sys", "ov-mini"].every(id => document.getElementById(id)?.textContent.trim().length > 0);
  return [hs, !document.getElementById("main").innerText.includes("did not render"), /PRs merged in 7 days/.test(document.getElementById("ov-mini").textContent) && document.querySelector("#ov-mini [data-focus=\"ov-merged\"] .big").textContent === "6"].join("|")')"
# Overview layout: no sideways scroll at 500 (the smallest headless width) and 640; the tiles go 1 wide in a
# phone-sized floor card; Spend and Today share a row at 1280 and stack at 640; Belts and Teams still fit.
LAY='const cols = () => getComputedStyle(document.querySelector("#ov-floor .ovtiles")).gridTemplateColumns.split(" ").length;
  const row = () => Math.abs(document.getElementById("ov-spend").getBoundingClientRect().top - document.getElementById("ov-teams").getBoundingClientRect().top) < 2;
  const fits = document.documentElement.scrollWidth <= innerWidth, c2 = cols(); document.getElementById("ov-floor").style.width = "330px"; await new Promise(r => setTimeout(r, 50));
  return [fits, c2, cols(), row()].join("|")'
ck "overview at 500 px: no sideways scroll, tiles 1 wide, 1 wide in a phone-sized card, cards stacked" "true|1|1|false" "$(bash "$p" '#overview' --fixture "$O" --width 500 --probe "$LAY")"
ck "overview at 640 px: the same" "true|2|1|false" "$(bash "$p" '#overview' --fixture "$O" --width 640 --probe "$LAY")"
ck "overview at 1280 px: 4 tiles a row; Spend and Teams share a row" "true|4|1|true" "$(bash "$p" '#overview' --fixture "$O" --width 1280 --probe "$LAY")"
for r in '#pipeline/belts' '#teams'; do
  ck "$r at 500 px still has no sideways scroll" "true" "$(bash "$p" "$r" --fixture "$F" --width 500 --probe 'return document.documentElement.scrollWidth <= innerWidth')"
done
# Epic review 1 fixes: the Merged and Cost cards open Stats PRs on 7 days and agree with it; a failed Jira queue
# read is not '0 ready'; a stale agents feed is unknown on the chip and the floor too.
ck "review 1: the Cost card opens Stats PRs on 7 days with the same figure; a Jira outage is not 0 ready; a stale agents feed is unknown everywhere" "true|true|true" "$(bash "$p" '#overview' --fixture "$O" --width 1280 --probe '
  const w = () => new Promise(r => setTimeout(r, 150)); localStorage.setItem("statsFilter", JSON.stringify({ ...SF_DEFAULT, range: "30d" })); SF = { ...SF_DEFAULT, range: "30d" };
  const card = document.querySelector("#ov-mini [data-focus=\"ov-cost\"] .big").textContent; document.querySelector("#ov-mini [data-focus=\"ov-cost\"]").click(); await w();
  const kpi = [...document.querySelectorAll("#s-stats .scard")].find(c => c.querySelector(".lbl").textContent === "Cost per merged PR")?.querySelector(".v").textContent;
  const a = location.hash === "#stats/prs" && SF.range === "7d" && kpi === card;
  location.hash = "#overview"; await w(); SNAP.queue = { fetch_failed: true, ready: [], skipped: [] }; render();
  const b = /ready tickets unknown, Jira fetch failed/.test(document.getElementById("ov-sys").innerText) && !/0 tickets are ready/.test(document.getElementById("ov-sys").innerText);
  STATE.agents_age_seconds = 1200; STATE.agents_interval = 30; render();
  const c = /^\? at work now/.test(document.querySelector(".ovchip").textContent) && /Sandboxes unknown: the agents feed is 20 min old/.test(document.getElementById("ov-floor").textContent) && /\?/.test(document.querySelector("#ov-needs .big").textContent);
  return [a, b, c].join("|")')"
ck "review 2: 'Merged, 7 days' on Overview equals the Stats PRs Merged card it opens, for a PR opened 10 days ago" "2|2" "$(bash "$p" '#overview' --fixture "$O" --width 1280 --probe '
  const w = () => new Promise(r => setTimeout(r, 150)), ago = d => new Date(Date.now() - d * 86400000).toISOString();
  STATS = { ...STATS, prs: [{ n: 1, key: "EX-1", title: "a", state: "MERGED", src: "pipeline", created: ago(10), merged: ago(1) }, { n: 2, key: "EX-2", title: "b", state: "MERGED", src: "pipeline", created: ago(2), merged: ago(1) }] };
  renderOvMini(); const o = document.querySelector("#ov-mini [data-focus=\"ov-merged\"] .big").textContent; document.querySelector("#ov-mini [data-focus=\"ov-merged\"]").click(); await w();
  return [o, [...document.querySelectorAll("#s-stats .scard")].find(c => c.querySelector(".lbl").textContent === "Merged")?.querySelector(".v").textContent].join("|")')"
# Epic review 3: the range buttons keep the focus; Stats PRs shows a week of merges of older PRs; a stale agents
# feed makes routine runs unknown.
ck "review 3: range buttons keep the focus across a click and a poll; Stats PRs shows merges of older PRs; routine runs unknown on a stale agents feed" "true|1|1|true" "$(bash "$p" '#overview' --fixture "$O" --width 1280 --probe '
  const w = () => new Promise(r => setTimeout(r, 150)), ago = d => new Date(Date.now() - d * 86400000).toISOString();
  const b = document.querySelector("[data-ovrange=\"7d\"]"); b.focus(); b.click(); await w(); AGENTS.runners[0].agent_alive = false; render(); await w();
  const a = document.activeElement?.dataset.focus === "ovr-7d" && document.querySelector("[data-ovrange=\"7d\"]").getAttribute("aria-pressed") === "true";
  STATS = { ...STATS, prs: [{ n: 1, key: "EX-1", title: "a", state: "MERGED", src: "pipeline", created: ago(10), merged: ago(2) }] }; renderOvMini();
  const o = document.querySelector("#ov-mini [data-focus=\"ov-merged\"] .big").textContent; document.querySelector("#ov-mini [data-focus=\"ov-merged\"]").click(); await w();
  const k = [...document.querySelectorAll("#s-stats .scard")].find(c => c.querySelector(".lbl").textContent === "Merged")?.querySelector(".v").textContent;
  SF = { ...SF, src: "slack" }; LAST["s-stats"] = ""; renderStats(); const k2 = /No PR opened or merged in this range matches these filters/.test(document.getElementById("s-stats").textContent);
  location.hash = "#overview"; await w(); TEAM_ADMIN = { admin: true }; AGENTS.sessions = [{ key: "agent-rt0009", state: "active", agent_alive: true, routine_run: 9, routine_name: "Ghost run", created: Date.now() / 1000 }];
  STATE.agents_age_seconds = 1200; STATE.agents_interval = 30; render(); const t = document.getElementById("ov-sys").innerText;
  return [a, o, k2 ? k : "filter ignored", /Routine runs unknown/.test(t) && !/Ghost run runs now/.test(t)].join("|")')"
# Overview at a glance (O6): the KPI change, Teams by profile, the free-slot line, Recent runs and its failed read.
ck "O6 KPIs: the change against the period before in %, points and minutes, colored by which way is good" "+50%|bad|+25 pts|good|+14 min|bad|75%" "$(bash "$p" '#overview' --fixture "$O" --width 1280 --probe '
  const DAY = 86400000, iso = d => new Date(Date.now() - d * DAY).toISOString(), P = (d, pr, min, usd) => ({ at: iso(d), src: "pipeline", pr, min, usd, key: "K" });
  STATS = { ...STATS, rows: [P(1, true, 10, 10), P(1, true, 20, 10), P(2, true, 30, 5), P(2, false, 40, 5), P(9, true, 10, 10), P(9, false, 12, 10)] }; STATS_ERR = null; OV_RANGE = "7d"; renderOvMini();
  const g = f => { const c = document.querySelector(`#ov-mini [data-focus="${f}"] .chg`); return [c?.textContent, c?.classList.contains("good") ? "good" : c?.classList.contains("bad") ? "bad" : ""]; };
  return [...g("ov-spend-k"), ...g("ov-rate"), ...g("ov-median"), document.querySelector("#ov-mini [data-focus=\"ov-rate\"] .big").textContent].join("|")')"
ck "O6 Teams: rows by stats profile (none is fxa), work now by team, runs and PRs in the range, the budget bar, no link for a bad name" "fxa|1,2,1|0,1,0|warn 90%|DIV" "$(bash "$p" '#overview' --fixture "$O" --width 1280 --probe '
  const iso = d => new Date(Date.now() - d * 86400000).toISOString();
  TEAMS = { teams: [{ profile: "two", label: "Two", access: { open: true }, budget: { month_usd: 45, month_cap: 50 } }, { profile: "fxa", label: "FxA" }, { profile: "../x", label: "Bad" }] };
  STATS = { ...STATS, rows: [{ at: iso(1), src: "pipeline", pr: true, usd: 3 }, { at: iso(1), src: "slack", usd: 1, profile: "fxa" }, { at: iso(2), src: "slack", usd: 2, profile: "two" }, { at: iso(40), src: "slack", usd: 9, profile: "two" }] };
  OV_RANGE = "30d"; renderOvTeams(); const r = p => document.querySelector(`#ov-teams [data-team="${p}"]`), nums = p => [...r(p).querySelectorAll(".num")].map(e => e.textContent).join(","), bar = r("two").querySelector(".ovbar i");
  return [document.querySelector("#ov-teams [data-team]").dataset.team, nums("fxa"), nums("two"), `${bar.className} ${bar.style.width}`, r("../x").tagName].join("|")')"
ck "O6 Running now: busy tiles only, the free slots on one line, and an empty floor says when the last run ended and the next pass" "3|3 free: ex-auto-3, 4, 5|true" "$(bash "$p" '#overview' --fixture "$O" --width 1280 --probe '
  const a = document.querySelectorAll("#ov-floor .ft").length, b = document.querySelector("#ov-floor .ovfree").textContent.split(" · ")[0];
  AGENTS.runners = []; AGENTS.sessions = []; AGENTS.pool = AGENTS.pool.map(x => ({ ...x, agent: null, busy: false })); render();
  return [a, b, /^Nothing runs now · the last run ended .+ago · next pass in \d+ min$/.test(document.querySelector("#ov-floor .emptybox").textContent)].join("|")')"
ck "O6 Recent runs: a badge per outcome, PR links only to GitHub pulls, merged from pr_state, today's counts, escaped" "PR #312|running|done|PR #301 merged|answered|no change|failed|true|true" "$(bash "$p" '#overview' --fixture "$O" --width 1280 --probe '
  const bs = [...document.querySelectorAll("#ov-runs .ovrun .r .ovpill")].map(e => e.textContent);
  const a = document.querySelector("#ov-runs a.ovpill[href=\"https://github.com/example/repo/pull/301\"]")?.classList.contains("ok") && /(\d+ today|none today)/.test(document.querySelector("#ov-runs h2").textContent);
  RUNS = [{ at: new Date().toISOString(), src: "pipeline", key: "x\"><img src=x>", title: "<img src=x>", team: "<b>t</b>", outcome: "pr", pr_url: "javascript:alert(1)", pr_number: 5 }]; renderOvRuns();
  const b = !document.querySelector("#ov-runs img, #ov-runs b") && !document.querySelector("#ov-runs a.ovpill") && /PR #5/.test(document.getElementById("ov-runs").textContent);
  return [...bs, a, b].join("|")')"
ck "O6 review: the KPI tiles keep their order, Spend then Today then the rest, when a tile is not a link" "ov-spend-k|ov-today|ov-merged" "$(bash "$p" '#overview' --fixture "$O" --width 1280 --probe '
  const t = [...document.querySelectorAll("#ov-mini > .ovk, #ov-today")].sort((a, b) => a.getBoundingClientRect().top - b.getBoundingClientRect().top || a.getBoundingClientRect().left - b.getBoundingClientRect().left);
  return t.slice(0, 3).map(x => x.id || x.dataset.focus).join("|")')"
ck "O6 review: a failed stats feed puts its note on Teams and Recent runs and the Teams figures say unknown; today counts every stats row, not the card's" "true|true|true|true" "$(bash "$p" '#overview' --fixture "$O" --width 1280 --probe '
  const tm = () => document.getElementById("ov-teams").textContent, rn = () => document.getElementById("ov-runs").textContent;
  const now = new Date().toISOString(); STATS.rows ??= []; for (let i = 0; i < 14; i++) STATS.rows.push({ at: now, src: "pipeline", key: "EX-9" + i, kind: "fix", usd: 1, min: 3, pr: i < 5, profile: "example" });
  safeRender(renderOvRuns, "ov-runs"); const n = (rn().match(/(\d+) today/) || [])[1], cnt = Number(n) >= 14 && Number(n) > RUNS.length;
  STATS_ERR = "the stats read failed"; safeRender(renderOvTeams, "ov-teams"); safeRender(renderOvRuns, "ov-runs");
  const r = [/the stats read failed/i.test(tm()), /the stats read failed/i.test(rn()), !/\$\d/.test([...document.querySelectorAll("#ov-teams .ovteam:not(.hd) .bud b")].map(b => b.textContent).join("")), cnt];
  STATS_ERR = null; return r.join("|")')"
ck "O6 Recent runs: no endpoint, an error body and an HTTP error each say unavailable, never an empty list" "true|true|true" "$(bash "$p" '#overview' --fixture "$F" --width 1280 --probe '
  const t = () => document.getElementById("ov-runs").textContent, f0 = window.fetch, a = /Recent runs unavailable: the answer has no runs/.test(t());
  window.fetch = async u => String(u).includes("/api/runs/recent") ? new Response(JSON.stringify({ runs: [], error: "stats unavailable" })) : f0(u); await loadRuns(); const b = /Recent runs unavailable: stats unavailable/.test(t());
  window.fetch = async u => String(u).includes("/api/runs/recent") ? new Response("nope", { status: 404 }) : f0(u); await loadRuns(); window.fetch = f0;
  return [a, b, /Recent runs unavailable: HTTP 404/.test(t()) && !document.querySelector("#ov-runs .ovrun")].join("|")')"
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
  return [/7 days: 41 runs, 63 h/.test(a), /7 days: 23 sessions, peak 3 of 4 · boot median 41 s/.test(a), /Manager \$0\.21\/h · \$35 in 7 days, always on/.test(a), /Firecracker host stopped: it starts for the next session/.test(a),
    /Sessions used the host 3 h in 7 days/.test(a), /GCE sandboxes now \$0\.13\/h/.test(a), noHostAlways, /Firecracker host state unknown: the host did not answer/.test(b), !/Firecracker/.test(c),
    /2 of 4 busy/.test(d) && /1 on GCE/.test(d) && gseg, /7 days: unknown: Stats read failed/.test(e) && !/7 days: 0|used the host 0/.test(e)].join("|")')"
ck "i407 cards: an old agents feed gives ? on each card, not a 0" "3|false" "$(bash "$p" '#runners' --fixture "$C" --width 1280 --probe '
  const n = document.getElementById("sb-cards"); STATE.agents_age_seconds = 99999; renderSbCards();
  return [...n.querySelectorAll(".big")].filter(b => b.textContent === "?").length + "|" + /\b0 of|\$0\.00/.test(n.textContent)')"
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
exit $fail
