#!/usr/bin/env python3
"""The golden check of dashboard/stats.py: on one fixture store and its files, `fxa-sandbox-ctl snapshot --stats`
and stats.compute give the same JSON, key by key, with the store on and with it off. Then stats.parts.
  python3 dashboard/stats.check.py
"""
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
CTL = os.path.join(HERE, "..", "fxa-sandbox-ctl")
sys.path.insert(0, HERE)
import stats  # noqa: E402

fail = 0
NOW = int(time.time())
D = 86400


def check(name, ok, detail=""):
    global fail
    fail |= not ok
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f": {detail}"))


def iso(t):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


def where(a, b, path="$"):
    """The first path at which two JSON values differ, for a FAIL line."""
    if isinstance(a, dict) and isinstance(b, dict):
        for k in sorted(set(a) | set(b)):
            if k not in a or k not in b:
                return f"{path}.{k}: {a.get(k, '<none>')!r} vs {b.get(k, '<none>')!r}"
            if not stats.same(a[k], b[k]):
                return where(a[k], b[k], f"{path}.{k}")
    if isinstance(a, list) and isinstance(b, list) and len(a) == len(b):
        for i, (x, y) in enumerate(zip(a, b)):
            if not stats.same(x, y):
                return where(x, y, f"{path}[{i}]")
    return f"{path}: {json.dumps(a)[:300]} vs {json.dumps(b)[:300]}"


def jsonl(path, recs):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write("".join(json.dumps(r) + "\n" for r in recs))


def put(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


PR = "https://github.com/mozilla/fxa/pull/"
RUNS = [
    {"recorded_at": iso(NOW - 60 * D), "issue": "FXA-4", "kind": "fix", "cost_usd": 3.3, "wall_seconds": 1200, "model": "claude-opus-5-5"},
    {"recorded_at": iso(NOW - 40 * D), "issue": "FXA-1", "kind": "fix", "cost_usd": 2.505, "wall_seconds": 600, "model": "claude-opus-5-5",
     "pr": PR + "101", "cost_source": "proxy", "cost_models": {"claude-opus-5-5": 2.0, "claude-haiku-4-5": 0.505}, "messages": 12,
     "files_changed": 3, "launched_at": NOW - 40 * D - 700},
    {"recorded_at": iso(NOW - 20 * D), "issue": "FXA-3", "kind": "fix", "cost_usd": 0.125, "wall_seconds": 125, "launched_at": NOW - 20 * D - 200.5},
    {"recorded_at": iso(NOW - 10 * D), "issue": "FXA-2", "wall_seconds": 1830, "model": "claude-sonnet-5-5", "messages": 4},
    {"recorded_at": iso(NOW - 3 * D), "issue": "FXA-10", "kind": "fix", "cost_usd": 4.0, "wall_seconds": 900, "pr": PR + "103", "files_changed": 1},
    {"recorded_at": iso(NOW - 2 * D), "issue": "FXA-1", "kind": "feedback", "cost_usd": 1.125, "wall_seconds": 0, "model": "<synthetic>",
     "files_changed": 5},
]
SESSIONS = [
    {"key": "agent-aa01", "owner": "U1", "owner_name": "Example User", "created": NOW - 5 * D, "stopped_at": NOW - 5 * D + 3600,
     "state": "stopped", "summary": json.dumps({"cost": 2.5, "minutes": 30}), "pr_url": "https://github.com/mozilla/PyFxA/pull/12",
     "profile": "example", "runner_s": "120", "busy_s": 60, "boot_s": "", "res_peak": json.dumps({"cpu": 1.5}), "queued_s": 90,
     "boot_backend": "fc", "stop_reason": "done"},
    {"key": "agent-aa02", "owner": "U1", "created": NOW - 5 * D + 1800.7, "stopped_at": NOW - 5 * D + 7200, "state": "stopped",
     "resume_from": "agent-aa01", "runtime": "codex", "queued_s": 400, "verify_runs": "3x"},
    {"key": "agent-aa03", "owner": "U2", "created": NOW - 600, "state": "active", "summary": "not json"},
    {"key": "agent-aa04", "owner": "U2", "owner_name": "Example User", "created": NOW - 4 * D, "stopped_at": NOW - 4 * D + 60,
     "fix_pr": 90001, "fix_actor": "octo-example", "pr_url": PR + "90001", "state": "stopped"},
    {"key": "agent-dv01", "owner": "U1", "env": "dev", "created": NOW - 4 * D, "state": "stopped"},
    {"key": "agent-dr01", "owner": "U-DRYRUN", "created": NOW - 4 * D, "state": "stopped"},
]
LLM = [
    {"at": iso(NOW - 5 * D), "run": "agent-aa01", "model": "claude-opus-5-5", "usd": 1.0, "usd_cache_write": 0.1, "input_tokens": 10,
     "output_tokens": 20, "cache_read_input_tokens": 300, "cache_creation_input_tokens": 40},
    {"at": iso(NOW - 5 * D + 400), "run": "agent-aa01", "model": "claude-haiku-4-5", "usd": 0.125, "usd_cache_write": 0.2},
    {"at": iso(NOW - 5 * D + 450), "run": "agent-aa01", "model": "claude-opus-5-5", "usd": 0.5, "usd_cache_write": 0.3},
    {"at": iso(NOW - 4 * D), "run": "agent-dv01", "model": "claude-opus-5-5", "usd": 10},
    {"at": iso(NOW - 1 * D), "run": "pass-123", "model": "claude-sonnet-5-5", "usd": 0.31},
    {"at": iso(NOW - 1 * D), "run": "ask-abc123", "model": "claude-sonnet-5-5", "usd": 0.2},
    {"at": iso(NOW - 1 * D), "run": "ask-bbb111", "thread": "C1:1.000001", "model": "claude-sonnet-5-5", "usd": 0.4},
    {"at": iso(NOW - 600), "run": None, "model": "claude-haiku-4-5", "usd": 0.05},
    {"at": iso(NOW - 900), "run": "agent-aa03", "model": "claude-opus-5-5", "usd": 0.7},
]
ERRORS = [{"at": iso(NOW - 5 * D), "kind": "queue_dropped", "key": "agent-zz09", "source": "session", "sig": "s1"},
          {"at": iso(NOW - 5 * D), "kind": "crash", "key": None, "source": "session", "sig": "s2"}]


def fixture(root, store):
    """A home with every file snapshot_stats_json reads, and the env both sides run with."""
    home = os.path.join(root, "home")
    st = os.path.join(home, ".claude", "state")
    ps = os.path.join(st, "fxa-ai-fixme")
    jsonl(os.path.join(ps, "agent-runs.jsonl"), RUNS)
    jsonl(os.path.join(ps, "job-costs.jsonl"), [
        {"at": iso(NOW - 1 * D), "job": "pass", "run": "pass-123", "cost_usd": 0.5, "duration_ms": 125000,
         "models": ["claude-haiku-4-5", "claude-sonnet-5-5"]},
        {"at": iso(NOW - 1 * D + 60), "job": "pass", "cost_usd": 0.475, "duration_ms": 30000},
        {"at": iso(NOW - 2 * D), "job": "triage", "cost_usd": 1.0, "models": ["claude-haiku-4-5"]}])
    jsonl(os.path.join(ps, "answers.jsonl"), [
        {"at": iso(NOW - 1 * D), "id": "ask-abc123", "secs": 20, "cost_usd": 0.12, "turns": 3, "thread": "C2:2.000002", "q": "Why does login fail?"},
        {"at": iso(NOW - 1 * D), "id": "ask-bbb111", "secs": 30, "cost_usd": 0.2, "turns": 5, "upgrade": True},
        {"at": iso(NOW - 1 * D), "id": "ask-ccc333", "secs": 9, "cost_usd": 0.3, "error": True},
        {"at": iso(NOW - 1 * D), "id": "ask-def456", "env": "dev", "cost_usd": 0.4},
        {"at": iso(NOW - 1 * D), "id": "timing1", "cost_usd": 0.3}])
    jsonl(os.path.join(ps, "passes.jsonl"), [
        {"at": NOW - 1 * D, "queued": 5, "awaiting": 2, "inflight": 1, "work": True, "merged": 1, "woke": {"queue": 1, "drain": 2}},
        {"at": NOW - 1 * D + 60, "queued": 7, "awaiting": 3, "inflight": 2, "work": False, "rejected": 1, "woke": {"drain": 1}},
        {"at": NOW - 3 * D, "queued": None, "awaiting": 0, "inflight": 0, "work": False}])
    for k, v in (("FXA-1.queued-at", f"{NOW - 41 * D}\n"), ("FXA-10.queued-at", f"{NOW - 4 * D}\n"), ("FXA-99.queued-at", f"{NOW}\n"),
                 ("FXA-3.queued-at", f"x{NOW - 19 * D}"), ("FXA-1.attempts", "3\n"), ("FXA-10.attempts", ""),
                 ("FXA-2.feedback-rounds", "1\n2\n"), ("FXA-1.jira.json", '{"assignee": "Example Person", "status": "Done"}')):
        put(os.path.join(ps, k), v)
    jsonl(os.path.join(ps, "prs.json"), [[
        {"number": 101, "title": "t101", "headRefName": "fxa-1", "state": "MERGED", "createdAt": iso(NOW - 40 * D + 600),
         "mergedAt": iso(NOW - 39 * D), "closedAt": iso(NOW - 39 * D), "mergedBy": {"login": "octo-example"}, "additions": 5, "deletions": 2},
        {"number": 102, "title": "t102", "headRefName": "agent-ab12", "state": "OPEN", "createdAt": iso(NOW - 5 * D),
         "mergedAt": None, "closedAt": None, "mergedBy": None, "additions": 1, "deletions": 0},
        {"number": 103, "title": "t103", "headRefName": "FXA-10", "state": "OPEN", "createdAt": iso(NOW - 3 * D),
         "mergedAt": None, "closedAt": None, "mergedBy": None, "additions": 9, "deletions": 9}]])
    now = iso(NOW - 60)
    jsonl(os.path.join(st, "memory.jsonl"), [
        {"at": now, "run": "agent-aa01", "result": "saved", "added": 1, "inbox": 2, "dropped": 1},
        {"at": now, "run": "agent-aa02", "result": "pii_blocked", "added": 0, "inbox": 0, "dropped": 0},
        {"at": "2020-01-01T00:00:00Z", "run": "agent-old", "result": "saved", "added": 9, "inbox": 9, "dropped": 9},
        {"at": now, "run": "digest", "result": "opened", "added": 3, "inbox": 1, "dropped": 0}])
    prof = os.path.join(root, "profiles")
    for p in ("fxa", "example", "quiet"):
        put(os.path.join(prof, p, "profile.conf"), "")
    put(os.path.join(st, "teams", "example-two.json"), "{}")
    jsonl(os.path.join(st, "example", "agent-runs.jsonl"), [
        {"recorded_at": iso(NOW - 2 * D), "issue": "EX-1", "kind": "fix", "cost_usd": 2.5, "cost_source": "proxy", "wall_seconds": 300, "pr": PR + "103"}])
    # The team's own list: its repo's #102 is not FxA's, and FxA's #103 (its run's PR) is listed once.
    ex = "https://github.com/example/team-repo/pull/"
    jsonl(os.path.join(st, "example", "prs.json"), [[
        {"number": 102, "title": "e102", "headRefName": "EX-2", "state": "MERGED", "createdAt": iso(NOW - 4 * D), "mergedAt": iso(NOW - 3 * D),
         "closedAt": iso(NOW - 3 * D), "mergedBy": {"login": "octo-example"}, "additions": 2, "deletions": 1, "url": ex + "102"},
        {"number": 103, "title": "t103", "headRefName": "FXA-10", "state": "OPEN", "createdAt": iso(NOW - 3 * D),
         "mergedAt": None, "closedAt": None, "mergedBy": None, "additions": 9, "deletions": 9, "url": PR + "103"}]])
    put(os.path.join(st, "example", "EX-2.jira.json"), '{"assignee": "Example Person", "status": "In Review"}')
    jsonl(os.path.join(st, "example", "job-costs.jsonl"), [{"at": iso(NOW - 2 * D), "job": "pass", "run": "pass-123", "cost_usd": 0.9}])
    jsonl(os.path.join(st, "example", "passes.jsonl"), [{"at": NOW - D, "work": True}, {"at": NOW - 2 * D, "work": False}, {"at": NOW - 9 * D, "work": True}])
    jsonl(os.path.join(st, "example-two", "passes.jsonl"), [{"at": NOW - 3600, "work": False}])
    sd, proxy, errs, db = os.path.join(root, "sessions"), os.path.join(root, "proxy"), os.path.join(root, "errors.jsonl"), os.path.join(root, "fxa.db")
    bin_ = os.path.join(root, "bin")
    put(os.path.join(bin_, "gh"), "#!/bin/sh\nexit 1\n")
    os.chmod(os.path.join(bin_, "gh"), 0o755)
    # FXA_NO_DOTENV: a checkout's .env (a team record, FXA_DB) must not reach the fixture's ctl, as in CI.
    env = {"PATH": bin_ + os.pathsep + os.environ.get("PATH", ""), "HOME": home, "LC_ALL": "C", "TMPDIR": root, "FXA_NO_DOTENV": "1",
           "FXA_FIXME_STATE": ps, "FXA_FIXME_RUNS": os.path.join(ps, "agent-runs.jsonl"), "FXA_SESSION_DIR": sd,
           "FXA_LLM_PROXY_DIR": proxy, "FXA_ERRORS_FILE": errs, "FXA_MEMORY_LOG": os.path.join(st, "memory.jsonl"),
           "FXA_PROFILES_DIR": prof, "FXA_TEAMS_DIR": os.path.join(st, "teams"), "FXA_DB": db, "FXA_SESSION_MAX": "3",
           "FXA_FC_SLOTS": "1", "FXA_AGENT_MODEL": "claude-opus-5-5", "FXA_CODEX_MODEL": "gpt-6-astra", "FXA_DB_BACKUP_URI": "",
           "FXA_SESSION_STORE_URI": "", "FXA_SESSION_BACKUP_URI": "", "FXA_ERRORS_URI": ""}
    if store:
        subprocess.run([CTL, "db", "init"], env=env, check=True, capture_output=True)
        con = sqlite3.connect(db, isolation_level=None)
        con.executemany("INSERT INTO sessions (key, data) VALUES (?, ?)", [(s["key"], json.dumps(s)) for s in SESSIONS])
        con.executemany("INSERT INTO ingest (tbl, j) VALUES (?, ?)", [("llm_calls", json.dumps(x)) for x in LLM] + [("errors", json.dumps(e)) for e in ERRORS])
        con.close()
    else:
        for s in SESSIONS:
            put(os.path.join(sd, s["key"] + ".json"), json.dumps(s, indent=1))
        jsonl(os.path.join(proxy, "usage.jsonl"), LLM)
        jsonl(errs, ERRORS)
    return env


def golden(store):
    root = tempfile.mkdtemp()
    try:
        env = fixture(root, store)
        p = subprocess.run([CTL, "--pipeline", "fxa", "snapshot", "--stats"], env=env, capture_output=True, text=True, timeout=120)
        try:
            shell = json.loads(p.stdout)
        except ValueError:
            check(f"golden ({'store' if store else 'files'}): the shell gives JSON", False, (p.stdout + p.stderr)[-400:])
            return
        con = sqlite3.connect(env["FXA_DB"]) if store else None
        port = stats.compute(con, stats.files("fxa", env))
        name = "store" if store else "files"
        check(f"golden ({name}): the same top-level keys", sorted(shell) == sorted(port or {}), f"{sorted(shell)} vs {sorted(port or {})}")
        for k in sorted(shell):
            check(f"golden ({name}): {k} is equal", k in (port or {}) and stats.same(shell[k], port[k]), where(shell.get(k), (port or {}).get(k), k))
        check(f"golden ({name}): stats.diff finds no key", stats.diff(shell, port) == [], stats.diff(shell, port))
        # The fixture reaches each branch: else an equal answer proves little.
        rows = {(r["src"], r["key"]) for r in shell["rows"]}
        check(f"golden ({name}): the fixture gives every row source", {"pipeline", "slack", "depfix", "pass", "answer"} <= {s for s, _ in rows}, rows)
        check(f"golden ({name}): the fixture gives llm, load, pipeline, memory, teams and PRs",
              bool(shell["llm"].get("days")) and bool(shell["load"]["days"]) and bool(shell["pipeline"]["waits"]) and bool(shell["memory"])
              and "example" in shell.get("team_passes", {}) and len(shell["prs"]) == 4, json.dumps(shell)[:300])
        check(f"golden ({name}): a team's list joins once per (repo, number), with the team of the work on it",
              sorted(f"{p['repo']}#{p['n']} {p['team']}" for p in shell["prs"])
              == ["example/team-repo#102 example", "mozilla/fxa#101 fxa", "mozilla/fxa#102 fxa", "mozilla/fxa#103 example"],
              [f"{p['repo']}#{p['n']} {p['team']}" for p in shell["prs"]])
    finally:
        shutil.rmtree(root, ignore_errors=True)


golden(True)
golden(False)

# The recompute time. stats.Live runs it in the hub's thread and holds the GIL, so it must stay short as the store grows.
RECOMPUTE_MS = 500


def recompute_ms(n):
    """The time of one stats.compute on the fixture store with each run, session and LLM call n times over."""
    global RUNS, SESSIONS, LLM
    keep = RUNS, SESSIONS, LLM
    RUNS = [dict(r, issue=r["issue"] + (str(i) if i else "")) for i in range(n) for r in keep[0]]
    SESSIONS = [dict(x, key=x["key"] + (f"{i:04d}" if i else "")) for i in range(n) for x in keep[1]]
    LLM = [x for _ in range(n) for x in keep[2]]
    root = tempfile.mkdtemp()
    try:
        env = fixture(root, True)
        con, f = sqlite3.connect(env["FXA_DB"]), stats.files("fxa", env)
        stats.compute(con, f)
        t = time.perf_counter()
        stats.compute(con, f)
        return (time.perf_counter() - t) * 1000
    finally:
        RUNS, SESSIONS, LLM = keep
        shutil.rmtree(root, ignore_errors=True)


one, big = recompute_ms(1), recompute_ms(100)
check(f"recompute: {one:.0f} ms on the fixture store, {big:.0f} ms on it 100 times over (budget {RECOMPUTE_MS} ms)", big < RECOMPUTE_MS)

root = tempfile.mkdtemp()
env = fixture(root, False)
os.remove(env["FXA_FIXME_RUNS"])
check("compute: an empty run log is None, as the shell's null", stats.compute(None, stats.files("fxa", env)) is None)
shutil.rmtree(root, ignore_errors=True)
check("jq round: half away from zero, not to even", (stats.r2(0.125), stats.jround(2.5), stats.jround(-2.5)) == (0.13, 3, -3))
check("jq order: null, false, true, numbers, strings", stats.sort_by(["a", 1, None, True, False]) == [None, False, True, 1, "a"])

# stats.parts: a C1 frame from one copy to the next.
old = {"rows": [{"key": "FXA-1", "usd": 1}], "llm": {"days": []}, "prs": [], "prs_at": 1, "load": {"cap": 2, "days": []}}
new = json.loads(json.dumps(old))
check("parts: no change gives None", stats.parts(old, new) is None)
new["rows"].insert(0, {"key": "FXA-2", "usd": 2})
new["llm"] = {"days": [{"day": "2026-11-01"}]}
f = stats.parts(old, new)
check("parts: a new row and a changed part, with base and etag", f == {"base": stats.etag(old), "etag": stats.etag(new),
      "rows_add": [{"key": "FXA-2", "usd": 2}], "llm": new["llm"]}, f)
check("parts: the etag is the one server.py sends", stats.etag(old) == '"%s"' % __import__("hashlib").sha1(json.dumps(old).encode()).hexdigest()[:20])
new["rows"][1]["usd"] = 3
check("parts: a changed past row is a reload, with no part", stats.parts(old, new) == {"base": stats.etag(old), "etag": stats.etag(new), "reload": True})
new = dict(old, team_passes={"example": {"passes": 1}})
check("parts: a new part is sent whole", stats.parts(old, new).get("team_passes") == {"example": {"passes": 1}})
check("parts: a part that is gone is a reload", stats.parts(new, old).get("reload") is True)
check("parts: from or to null is a reload", stats.parts(None, old).get("reload") is True and stats.parts(old, None).get("reload") is True)
check("same: true is not 1, 1 is 1.0", not stats.same(True, 1) and stats.same(1, 1.0) and stats.diff({"a": True}, {"a": 1}) == ["a"])

# stats.Live: pokes inside the wait give one recompute, a change sends one frame, the diff logs at most hourly.
copies, sent, real = iter([{"rows": [], "llm": {}}, {"rows": [{"key": "FXA-1"}], "llm": {}}]), [], stats.compute
stats.compute, stats.DEBOUNCE_S = lambda con, f: next(copies), 0.2
live = stats.Live(lambda: None, {}, sent.append)
live.recompute()
for _ in range(5):
    live.poke()
time.sleep(0.6)
check("live: five pokes in the wait give one recompute and one frame with the new row",
      [f.get("rows_add") for f in sent] == [[{"key": "FXA-1"}]] and live.tag == stats.etag(live.data), sent)
check("live: the hourly diff counts the keys that differ, then waits an hour",
      (live.hourly({"rows": [], "llm": {}}), live.hourly({})) == (1, None))
stats.compute = real

sys.exit(fail)
