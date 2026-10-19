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
# Sandboxes: a stopped GCE instance is not up. It has its own group and a fix, with no lifetime meter.
R="$(mktemp "${TMPDIR:-/tmp}/fxa-runners.XXXXXX")"
jq '."/api/snapshot".agents.instances = [{"name":"agent-agent-41c0e6","state":"terminated","age_seconds":213277,"max_seconds":5400,"where":"gce"},
  {"name":"agent-fxa-9","state":"running","age_seconds":600,"max_seconds":5400,"where":"gce"}]' "$F" > "$R"
ck "a stopped instance: its own group, a fix, not counted up, no meter" "Stopped, needs a fix;Sandboxes up|1 sandbox up · 1 stopped|true|true|1" "$(bash "$p" '#runners' --fixture "$R" --width 1280 --probe '
  const h = [...document.querySelectorAll("#side h3, #side .grp, #side [data-group]")].map(e => e.textContent.trim()).filter(Boolean);
  const pool = document.querySelector("#s-pool h2")?.textContent ?? "", stop = [...document.querySelectorAll("#s-pool .slot")].find(e => e.textContent.includes("41c0e6"));
  return [h.join(";"), pool.replace(/burn.*/, "").split("free · ")[1]?.trim(), /fxa-sandbox-ctl stop agent-41c0e6/.test(stop?.textContent ?? ""), !!stop?.querySelector(".meter.none"), document.getElementById("n-runners").textContent].join("|")')"
rm -f "$R"
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
  const big = () => document.querySelector("#ov-mini .big").textContent, b = beltGroups().needs.length;
  const r1 = [big() === String(b), document.getElementById("n-overview").textContent === (b ? String(b) : document.querySelectorAll("#attn .alert").length ? "!" : ""), document.title.startsWith(b ? `(${b}) ` : "")];
  AGENTS.instances = [...(AGENTS.instances ?? []), { name: "agent-zz9", state: "running", age_seconds: 300 }]; render();
  const sb = [...document.querySelectorAll("#ov-mini .sub a")].find(a => a.hasAttribute("data-attn")); sb?.click();
  const r2 = [sb?.textContent, document.activeElement?.id];
  STATE.agents_age_seconds = 1200; STATE.agents_interval = 30; render();
  return [...r1, ...r2, big(), /unknown, agents feed/.test(document.querySelector("#ov-mini .sub").textContent)].join("|")')"
# The Merged and Cost cards (i380): the cost is the Stats PRs number; an unread or old PR list shows no 0;
# the focus stays on a card link across a poll; a renderer that throws does not stop the others.
ck "Merged and Cost cards: Stats number, no 0 for an unread or old list, focus kept, a throw stops nothing" "2|\$1.50|—|true|true|true" "$(bash "$p" '#overview' --fixture "$F" --width 1280 --probe '
  const now = Date.now(), iso = d => new Date(now - d * 86400000).toISOString(), card = k => document.querySelector(`#ov-mini [data-focus="${k}"]`);
  STATS = { prs: [{ n: 1, merged: iso(1) }, { n: 2, merged: iso(2) }, { n: 3, merged: iso(20) }], prs_at: Math.round(now / 1000) - 60, rows: [{ at: iso(1), usd: 2 }, { at: iso(3), usd: 1 }, { at: iso(30), usd: 50 }] };
  renderOvMini(); const m = card("ov-merged").querySelector(".big").textContent, c = card("ov-cost").querySelector(".big").textContent;
  const same = c === usd(costPerMerged(now - 7 * 86400000, now, STATS.prs, STATS.rows).per);
  // A value outside the links changes, so the card is rewritten: the focus must come back to the same link.
  card("ov-cost").focus(); const n0 = card("ov-cost"); AGENTS.instances = [{ name: "agent-zz8", state: "running", age_seconds: 300 }]; render();
  const kept = document.activeElement?.dataset.focus === "ov-cost" && document.activeElement !== n0 && /sandbox alert/.test(document.querySelector("#ov-mini .sub").textContent);
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
exit $fail
