#!/usr/bin/env bash
# The Overview's counts name what they count, and a stopped pipeline says what to do (dashboard/index.html).
#   bash skills/fxa-ctl-dev/page-ov-ux.check.sh
set -u
here="$(dirname "$0")"; fail=0
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
# No pass for 3 h: the health cell and the alert both read it.
jq '."/api/snapshot".snapshot.health.seconds_since_pass = 11000' "$here/page-fixture-overview.json" > "$tmp/f.json"
out="$(bash "$here/page.sh" '#overview' --fixture "$tmp/f.json" --width 1280 --probe '
  await new Promise(r => setTimeout(r, 300)); const ok = (c, m) => (c ? "ok   " : "FAIL ") + m;
  const txt = document.body.innerText, leg = [...document.querySelectorAll(".ovleg a")].map(a => a.innerText);
  const kinds = [...document.querySelectorAll("#ov-runs .ovrun")].filter(r => {
    const d = r.querySelector(".d > span:not(.tag)")?.innerText.toLowerCase(), t = r.querySelector(".t")?.innerText.toLowerCase() ?? "";
    return d && t.includes(d); });
  return [
    ok(document.getElementById("health").textContent === "no passes", "no pass for 3 h reads no passes, not down"),
    ok(txt.includes("the operator runs /fxa-automation in Claude Code"), "the no-pass alert names the next step"),
    ok(!txt.includes("wait on you"), "the footer queue cell does not say wait on you"),
    ok(/PRs? waits? on a review/.test(document.getElementById("n-pipeline").getAttribute("aria-label") ?? ""), "the Pipeline badge names what it counts"),
    ok(leg.length > 0 && !leg.some(l => / 0 runs/.test(l)), "the spend legend leaves out a source with no runs"),
    ok(kinds.length === 0, "no Activity row repeats its kind beside a title that names it"),
  ].join("\n");')"; rc=$?
[ "$rc" = 3 ] && { echo "SKIP (no Chrome)"; exit 0; }
printf '%s\n' "$out"; grep -q '^FAIL' <<< "$out" && fail=1
exit "$fail"
