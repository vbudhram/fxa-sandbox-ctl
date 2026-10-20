#!/usr/bin/env bash
# Probe families over the Overview cards of dashboard/index.html, so test.sh changed runs them for a change to the page.
# 1. Each card link into Stats opens a page that shows the same figure.
# 2. Each feed the Overview reads, set stale or failed: every card that reads it says so.
#   bash skills/fxa-ctl-dev/page-ov-family.check.sh
set -u
p="$(dirname "$0")/page.sh" O="$(dirname "$0")/page-fixture-overview.json"; fail=0
run() { local out rc; out="$(bash "$p" '#overview' --fixture "$O" --width 1280 --probe "$1")"; rc=$?
  [ "$rc" = 3 ] && { echo "SKIP (no Chrome): the Overview family probes did not run"; exit 0; }
  printf '%s\n' "$out"; grep -qv '^ok ' <<< "$out" && fail=1; }

# Every link with data-sfrange is a card that opens Stats; a new one is in the family with no change here.
# The figure on the Stats page is the KPI with the card's label up to the comma, or Spend.
run '
  const w = () => new Promise(r => setTimeout(r, 120)), out = [], seen = new Set();
  // A run today, so Today has a figure at any hour of the run.
  STATS.rows.push({ at: new Date().toISOString(), src: "slack", key: "agent-ex0t01", usd: 1.5, profile: "example" }); render(); await w();
  const links = () => [...document.querySelectorAll(".ov [data-sfrange]")].filter(a => !a.closest("[hidden]"));
  const ids = links().map(a => a.dataset.focus);
  if (ids.length < 5) out.push(`FAIL only ${ids.length} Stats links on Overview: the fixture lost its cards`);
  for (const id of ids) {
    if (seen.has(id)) { out.push(`FAIL two links share data-focus ${id}`); continue; } seen.add(id);
    const a = links().find(x => x.dataset.focus === id), sec = a.closest("section");
    const lbl = (a.querySelector(".lbl")?.textContent ?? "Spend").split(",")[0].trim();
    const fig = (a.querySelector(".big")?.textContent ?? a.textContent.match(/\$[\d,]+\.\d\d/)?.[0] ?? sec.querySelector(".big")?.textContent ?? "").trim();
    a.click(); await w();
    const kp = [...document.querySelectorAll("#s-stats .scard")].find(c => c.querySelector(".lbl").textContent === lbl)?.querySelector(".v").textContent.trim();
    out.push(`${fig && kp === fig ? "ok  " : "FAIL"} ${sec.id} ${id}: Overview ${fig || "no figure"}, ${location.hash} ${SF.range} ${lbl} ${kp ?? "not found"}`);
    location.hash = "#overview"; await w();
  }
  return out.join("\n")'

# The feeds the Overview reads, and how a feed is set stale or failed. CARDS names the feeds each card reads;
# a card in the page and not in CARDS fails, so a new card gets its feeds named here.
# Stale is old data past 3 intervals; failed is what the server sends when a read fails, with or without old data.
run '
  const CARDS = { "ov-head": ["agents"], "ov-needs": ["snapshot", "agents"], "ov-mini": ["stats"], "ov-today": ["stats"], "ov-spend": ["stats"],
    "ov-teams": ["stats", "agents", "teams"], "ov-floor": ["agents"], "ov-runs": ["stats", "runs"], "ov-sys": ["snapshot", "agents"] };
  const FEEDS = {
    "snapshot stale": () => { STATE.age_seconds = 9999; }, "snapshot failed": () => { STATE.error = "the snapshot read failed"; SNAP = STATE.snapshot = null; },
    "stats stale": () => { STATE.stats_age_seconds = 9999; }, "stats failed": () => { STATS_ERR = "the stats feed could not be read (HTTP 500)"; },
    "agents stale": () => { STATE.agents_age_seconds = 9999; }, "agents failed": () => { STATE.agents_error = "the agents read failed"; },
    "teams stale": () => { Object.assign(TEAMS, { error: "the teams read failed", age_seconds: 9999, interval: 300 }); }, "teams failed": () => { TEAMS = { teams: [], error: "the teams read failed" }; },
    "runs failed": () => { RUNS = null; RUNS_ERR = "HTTP 500"; } };
  const UNKNOWN = /unknown|\?|could not be read|min old|unavailable|not current|failed/i;
  const w = () => new Promise(r => setTimeout(r, 60)), txt = id => document.getElementById(id).innerText, out = [];
  const ids = [...document.querySelectorAll(".ov section[id]")].map(s => s.id).filter(id => id !== "ov-kpis");
  ids.filter(id => !CARDS[id]).forEach(id => out.push(`FAIL ${id} is an Overview card with no feeds named in CARDS`));
  const save = JSON.stringify({ STATE, STATS, TEAMS, RUNS, STATS_ERR, RUNS_ERR }), restore = () => { const s = JSON.parse(save);
    STATE = s.STATE; SNAP = STATE.snapshot; AGENTS = STATE.agents; STATS = s.STATS; TEAMS = s.TEAMS; RUNS = s.RUNS; STATS_ERR = s.STATS_ERR; RUNS_ERR = s.RUNS_ERR; };
  for (const [feed, set] of Object.entries(FEEDS)) {
    restore(); render(); await w(); const fresh = Object.fromEntries(ids.map(id => [id, txt(id)]));
    set(); render(); await w();
    for (const id of ids.filter(id => CARDS[id]?.includes(feed.split(" ")[0]))) {
      const t = txt(id), ok = UNKNOWN.test(t) && t !== fresh[id];
      out.push(`${ok ? "ok  " : "FAIL"} ${feed}: ${id} ${ok ? "says unknown or old" : "shows the feed as current: " + t.replace(/\s+/g, " ").slice(0, 140)}`);
    }
  }
  restore(); render(); return out.join("\n")'
# A /api/teams request that fails (HTTP 503, as the gateway answers when the manager is down) keeps the rows with a note.
tt="$(bash "$p" '#overview' --fixture "$O" --probe '
  const w = ms => new Promise(r => setTimeout(r, ms)); await w(300); const real = window.fetch;
  window.fetch = (u, o) => String(u).startsWith("/api/teams") ? Promise.resolve(new Response("", { status: 503 })) : real(u, o);
  await loadTeams(); await w(100); window.fetch = real;
  return /teams feed failed: the teams read failed \(HTTP 503\)/.test(document.getElementById("ov-teams").textContent)')"
if [ "$tt" = true ]; then echo "ok   a failed /api/teams request keeps the Teams rows with a note"; else echo "FAIL a failed /api/teams request keeps the Teams rows with a note: got [$tt]"; fail=1; fi
# The first /api/teams request fails: Teams shows the error, not an empty list "from 0s ago".
tf="$(bash "$p" '#teams' --fixture "$O" --probe '
  const w = ms => new Promise(r => setTimeout(r, ms)); await w(300); const real = window.fetch;
  window.fetch = (u, o) => String(u).startsWith("/api/teams") ? Promise.resolve(new Response("", { status: 503 })) : real(u, o);
  TEAMS = null; TEAMS_AT = 0; await loadTeams(); renderTeams(); await w(100); window.fetch = real;
  const x = document.getElementById("s-teams").textContent; return /the teams read failed \(HTTP 503\)/.test(x) && !/ago/.test(x)')"
if [ "$tf" = true ]; then echo "ok   a first /api/teams request that fails shows the error on Teams"; else echo "FAIL a first /api/teams request that fails shows the error on Teams: got [$tf]"; fail=1; fi
exit $fail
