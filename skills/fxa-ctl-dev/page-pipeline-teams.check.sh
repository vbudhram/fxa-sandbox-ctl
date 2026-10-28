#!/usr/bin/env bash
# The Pipeline views over several teams: the picker, All teams joined with each row tagged, each row's own PR and Jira
# links, one team picked, and a private team's counts only (dashboard/index.html pipeSnap, renderPipeTeam).
#   bash skills/fxa-ctl-dev/page-pipeline-teams.check.sh
set -u
here="$(dirname "$0")"; fail=0; F="$(mktemp "${TMPDIR:-/tmp}/teams-fixture.XXXXXX")"; trap 'rm -f "$F"' EXIT
jq '."/api/snapshot".teams = {
  two: {snapshot: {team: {profile: "two", name: "Two", repo: "other/repo", jira_site: "https://jira2.example.com"},
        queue: {ready: [{key: "TWO-1", summary: "two ready"}], skipped: []}, inflight: [], review: [], blocked: [], open_prs: [],
        merged_prs: [{number: 55, key: "TWO-5", title: "fix(two): merged", created: "@iso-200000", merged: "@iso-3600", merged_by: "r"}]}},
  priv: {snapshot: {team: {profile: "priv", name: "Priv"}, redacted: true,
         counts: {ready: 1, skipped: 0, inflight: 2, review: 3, blocked: 0, open_prs: 0, merged_prs: 4}}}}' \
  "$here/page-fixture-pipeline.json" > "$F"
run() { local out rc; out="$(bash "$here/page.sh" "$1" --fixture "$F" --width 1280 --probe "$2")"; rc=$?
  [ "$rc" = 3 ] && { echo "SKIP (no Chrome)"; exit 0; }
  printf '%s\n' "$out"; grep -q '^FAIL' <<< "$out" && fail=1; }
P='await new Promise(r => setTimeout(r, 300)); const ok = (c, m) => (c ? "ok   " : "FAIL ") + m;
  const pick = async v => { const s = document.querySelector("[data-pteam]"); s.value = v; s.dispatchEvent(new Event("change", { bubbles: true })); await new Promise(r => setTimeout(r, 100)); };'
run '#pipeline/done' "$P"'
  const opts = [...document.querySelectorAll("[data-pteam] option")].map(o => o.textContent.trim());
  const two = document.querySelector("#s-done a[href=\"https://github.com/other/repo/pull/55\"]"), j = document.querySelector("#s-done a[href=\"https://jira2.example.com/browse/TWO-5\"]");
  const fxa = !!document.querySelector("#s-done a[href=\"https://github.com/example/app/pull/50\"]");
  return [ok(JSON.stringify(opts) === JSON.stringify(["All teams", "Example", "Two", "Priv (private)"]), "the picker lists All teams and each team, a private one marked: " + JSON.stringify(opts)),
    ok(two && j && fxa, "All teams: Done lists both teams, each PR and key linking to its own repo and Jira site")].join("\n");'
run '#pipeline/queue' "$P"'
  await pick("two"); const q = document.getElementById("s-queue").innerText;
  const a = q.includes("TWO-1") && !q.includes("FXA-30");
  await pick("priv"); const msg = document.getElementById("s-pteam").innerText;
  await pick(""); const q2 = document.getElementById("s-queue").innerText;
  return [ok(a, "one team picked: only its queue"), ok(/details for team admins/.test(msg) && /3 in review/.test(msg), "a private team: counts only, details for team admins: " + msg),
    ok(q2.includes("TWO-1") && q2.includes("FXA-30"), "All teams again: both queues")].join("\n");'
exit $fail
