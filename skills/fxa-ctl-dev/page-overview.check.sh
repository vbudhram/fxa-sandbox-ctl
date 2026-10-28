#!/usr/bin/env bash
# The Overview charts, layout, tabs and cards (split from page.check.sh, so the check pool runs the page probes in parallel).
#   bash skills/fxa-ctl-dev/page-overview.check.sh
set -u
p="$(dirname "$0")/page.sh"; fail=0
bash "$p" '#teams' --probe 'return 1' >/dev/null 2>&1; [ $? = 3 ] && { echo "SKIP (no Chrome): the page probes did not run; set CHROME to run them"; exit 0; }
ck() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; fail=1; fi; }
F="$(dirname "$0")/page-fixture-pipeline.json"
# The spend rows, as page-stats.check.sh sets them.
SP='const DAY = 86400000, noon = d => { const t = new Date(); t.setHours(12, 0, 0, 0); return new Date(t.getTime() - d * DAY).toISOString(); };
  const rows = []; for (let d = 0; d < 100; d++) [["pipeline", 1], ["pass", 0.5], ["slack", 0.25], ["answer", 0.125]].forEach(([src, u]) => rows.push({ at: noon(d), src, usd: d === 4 ? u * 20 : u, key: `K-${d}-${src}`, model: "claude-opus-5-5" }));
  rows.push({ at: noon(95), src: "pipeline", usd: 1000, key: "OLD-1" });
  STATS = { rows, prs: [1, 2, 3].map(n => ({ n, merged: noon(4), src: "pipeline" })), prs_at: Math.round(Date.now() / 1000) - 60, llm: { hour_usd: 0.42 } }; STATS_ERR = null;
  const statsSpend = r => { SF = { ...SF_DEFAULT, range: r }; STATS_TAB = "spend"; LAST["s-stats"] = ""; renderStats(); return [...document.querySelectorAll("#s-stats .stat")].find(c => c.querySelector(".lbl").textContent === "Spend").querySelector(".big").textContent; };'
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
  const a = document.querySelector("#ov-runs a.tag[href=\"https://github.com/example/repo/pull/301\"]")?.classList.contains("ok") && /(\d+ today|Nothing today)/.test(document.querySelector("#ov-runs > .sub").textContent);
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
exit $fail
