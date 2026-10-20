#!/usr/bin/env bash
# dashboard/index.html performance: stats row times parsed once, no polls in a hidden tab, a refresh polls until it lands.
#   bash skills/fxa-ctl-dev/page-perf.check.sh
set -u
p="$(dirname "$0")/page.sh" F="$(dirname "$0")/page-fixture-overview.json"; fail=0
ck() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; fail=1; fi; }
w='const w = ms => new Promise(r => setTimeout(r, ms));'
out="$(bash "$p" '#overview' --fixture "$F" --probe "$w"' await w(600); const o = Date.parse; let n = 0; Date.parse = x => (n++, o(x)); render(); Date.parse = o;
  return `${STATS.rows.length > 0 && STATS.rows.every(r => typeof r.ms === "number")}|${n < 500}`')"; rc=$?
[ "$rc" = 3 ] && { echo "SKIP (no Chrome): the page probes did not run; set CHROME to run them"; exit 0; }
ck "each stats row's time is parsed once, so a render does not call Date.parse thousands of times" "true|true" "$out"
ck "a hidden tab polls no sessions" "0" "$(PAGE_BUDGET=9000 bash "$p" '#overview' --fixture "$F" --probe "$w"' await w(300); Object.defineProperty(document, "hidden", { configurable: true, get: () => true });
  const real = window.fetch; let n = 0; window.fetch = (u, o) => (String(u).startsWith("/api/sessions") && n++, real(u, o)); await w(3500); window.fetch = real; return n')"
ck "a refresh polls the snapshot until the rebuild lands, then stops" "3" "$(PAGE_BUDGET=14000 bash "$p" '#overview' --fixture "$F" --probe "$w"' await w(400); const real = window.fetch; let n = 0;
  window.fetch = async (u, o) => { if (String(u).startsWith("/api/snapshot")) { n++; const d = await (await real(u, o)).json(); return new Response(JSON.stringify({ ...d, refreshing: n < 3 })); } return real(u, o); };
  document.getElementById("refresh").click(); await w(8500); window.fetch = real; return n')"
ck "at load, the page polls until a rebuild lands (feeds that slept while nobody looked)" "3|1" "$(PAGE_BUDGET=14000 bash "$p" '#overview' --fixture "$F" --probe "$w"' await w(400); const real = window.fetch; let n = 0;
  window.fetch = async (u, o) => { if (String(u).startsWith("/api/snapshot")) { n++; const d = await (await real(u, o)).json(); return new Response(JSON.stringify({ ...d, refreshing: n < 3 })); } return real(u, o); };
  pollFresh(0); await w(8500); window.fetch = real; return n')|$(grep -c '^pollFresh(0);$' "$(dirname "$0")/../../dashboard/index.html")"
ck "on another view a poll leaves the Overview cards and Stats alone, and opening the Overview draws its cards" "x|x|drawn" "$(bash "$p" '#pipeline' --fixture "$F" --probe "$w"' await w(600);
  const m = document.getElementById("ov-mini"), st = document.getElementById("s-stats"); m.innerHTML = "x"; st.innerHTML = "x";
  render(); await loadStats(); const a = m.textContent, b = st.textContent; location.hash = "#overview"; await w(300);
  return `${a}|${b}|${m.textContent !== "x" ? "drawn" : "empty"}`')"
[ "$fail" = 0 ] && echo "all checks pass"
exit "$fail"
