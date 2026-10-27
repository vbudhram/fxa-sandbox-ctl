#!/usr/bin/env bash
# Stats, the alerts, Needs you, the Merged, Cost and Spend cards, and daylight saving (split from page.check.sh, so the check pool runs the page probes in parallel).
#   bash skills/fxa-ctl-dev/page-stats.check.sh
set -u
p="$(dirname "$0")/page.sh"; fail=0
bash "$p" '#teams' --probe 'return 1' >/dev/null 2>&1; [ $? = 3 ] && { echo "SKIP (no Chrome): the page probes did not run; set CHROME to run them"; exit 0; }
ck() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; fail=1; fi; }
F="$(dirname "$0")/page-fixture-pipeline.json"
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
exit $fail
