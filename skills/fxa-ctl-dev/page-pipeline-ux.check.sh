#!/usr/bin/env bash
# Pipeline counts agree with the Overview and name their sets; a belt row names its stage at phone width (dashboard/index.html).
#   bash skills/fxa-ctl-dev/page-pipeline-ux.check.sh
set -u
here="$(dirname "$0")"; F="$here/page-fixture-pipeline.json"; fail=0
run() { local out rc; out="$(bash "$here/page.sh" "$1" --fixture "$F" --width "$2" --probe "$3")"; rc=$?
  [ "$rc" = 3 ] && { echo "SKIP (no Chrome)"; exit 0; }
  printf '%s\n' "$out"; grep -q '^FAIL' <<< "$out" && fail=1; }
P='await new Promise(r => setTimeout(r, 300)); const ok = (c, m) => (c ? "ok   " : "FAIL ") + m;
  const tile = n => [...document.querySelectorAll(".stat, .rtkpis > *")].find(e => e.innerText.toUpperCase().startsWith(n.toUpperCase()));'
run '#pipeline/belts' 1280 "$P"'
  const nv = ovNeeds(), t = tile("Needs you"), big = t?.querySelector(".big, b, strong")?.innerText ?? t?.innerText.split("\n")[1];
  return [ok(String(nv.total - nv.sandbox) === String(big).trim(), "Belts Needs you equals the Overview number (less sandbox alerts): " + big + " vs " + (nv.total - nv.sandbox)),
    ok(!document.body.innerText.includes("awaiting review"), "the Open PRs tile says in review, the Queue tab word"),
    ok(![...document.querySelectorAll(".belt .st")].some(s => /\d+ days?/.test(s.querySelector(".l1")?.innerText ?? "") && s.querySelector(".age")), "no belt row gives its wait twice")].join("\n");'
run '#pipeline/belts' 500 "$P"'
  const rows = [...document.querySelectorAll(".belt .stn")].filter(e => e.checkVisibility());
  return ok(rows.length > 0 && rows.every(e => getComputedStyle(e).display !== "none" && /^at \w/.test(e.innerText)), "at phone width each belt row names its stage");'
run '#pipeline/queue' 1280 "$P"'
  return ok(!(tile("Waits on a person")?.innerText ?? "").includes("held"), "the Waits on a person tile does not describe the held tickets");'
exit "$fail"
