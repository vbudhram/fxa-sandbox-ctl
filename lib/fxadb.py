"""The controller's SQLite store, for the Python writers and readers: the
dashboard, the LLM proxy and the MCP gateway. lib/db.sh owns the schema
(`fxa-sandbox-ctl db init`); this only connects. Use bound parameters, never
string formatting, for any value.
"""
import json
import os
import re
import sqlite3
import threading

PATH = os.environ.get("FXA_DB") or os.path.expanduser("~/.claude/state/fxa.db")


def connect(path=None, readonly=False):
    """A connection that waits up to 5 s for a writer, as every other client does."""
    p = path or PATH
    con = sqlite3.connect(f"file:{p}?mode=ro" if readonly else p, uri=readonly, timeout=5, isolation_level=None)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA busy_timeout = 5000")
    return con


# One connection per thread: the proxy and the gateway call ingest from ThreadingHTTPServer
# handlers, and sqlite3 refuses a connection made on another thread.
_LOCAL = threading.local()


def ingest(tbl, obj):
    """One log record into the store, mapped by the ingest triggers. Never raises:
    the caller's file is the fallback while the store proves itself."""
    con = getattr(_LOCAL, "con", None)
    try:
        if con is None:
            if not os.path.exists(PATH):
                return  # no store here (a test, or a host without db init): do not create an empty one
            con = _LOCAL.con = connect()
        con.execute("INSERT INTO ingest (tbl, j) VALUES (?, ?)", (tbl, obj if isinstance(obj, str) else json.dumps(obj)))
    except Exception:  # noqa: BLE001 - the file write already happened
        if con is not None:
            con.close()
        _LOCAL.con = None


def rows(con, sql, params=()):
    """The rows of one query as plain dicts, ready for json.dumps."""
    return [dict(r) for r in con.execute(sql, params)]


def routine_summary(con, now):
    """For the Teams page (admins only): per team and per routine, the 30-day runs and cost, and whether
    the routine failed (its newest ended run is failed or missed). A paused routine stays failed for
    itself, but is left out of its team's failed count and last failed run. No prompt, report or channel.
    Each routine also has its name, team, template, on (schedule or pr-label), paused and next run (epoch; null when paused or unreadable),
    and the lowest and highest cost of one run in 30 days (null with no costed run), for the form's cost hint."""
    import routine  # the one reader of a schedule; the dashboard loads it from lib/ beside this file
    since = now - 30 * 86400
    rts = rows(con, """SELECT id, team, paused, json_extract(data, '$.name') AS name, coalesce(json_extract(data, '$.template'), 'blank') AS template,
        coalesce(json_extract(data, '$.on'), 'schedule') AS "on",
        json_extract(data, '$.schedule') AS schedule, json_extract(data, '$.zone') AS zone FROM routines""")
    ended = rows(con, """SELECT r.routine_id AS rid, r.state, r.reason, r.session, coalesce(r.ended_at, r.started_at, 0) AS at, r.cost_usd
        FROM routine_runs r WHERE r.state NOT IN ('queued', 'claimed', 'started') ORDER BY at, r.id""")
    live = {r["routine_id"] for r in rows(con, "SELECT DISTINCT routine_id FROM routine_runs WHERE state IN ('queued', 'claimed', 'started')")}
    per, teams = {}, {}
    for r in rts:
        nxt = None
        if not r["paused"]:
            try:
                nxt = int(routine.runs(r, now, 1)[0].timestamp())
            except Exception:  # noqa: BLE001  a bad schedule or zone shows no next run, not a failed page
                nxt = None
        per[r["id"]] = {"name": r["name"], "team": r["team"], "template": r["template"], "on": r["on"], "paused": bool(r["paused"]), "next": nxt,
                        "runs_30d": 0, "cost_30d": 0.0, "cost_min_30d": None, "cost_max_30d": None, "failed": False, "last_end": None}
    last = {}
    for x in ended:
        p = per.get(x["rid"])
        if p is None:
            continue
        last[x["rid"]] = x
        p["last_end"] = x["at"] or None
        if x["at"] >= since:
            p["runs_30d"] += 1
            p["cost_30d"] += x["cost_usd"] or 0.0
            if x["cost_usd"]:
                p["cost_min_30d"] = min(p["cost_min_30d"] or x["cost_usd"], x["cost_usd"])
                p["cost_max_30d"] = max(p["cost_max_30d"] or 0.0, x["cost_usd"])
    for r in rts:
        p, x = per[r["id"]], last.get(r["id"])
        p["failed"] = bool(x and x["state"] in ("failed", "missed"))
        p["cost_30d"] = round(p["cost_30d"], 4)
        t = teams.setdefault(r["team"], {"routines": 0, "paused": 0, "failed": 0, "live": 0, "last_failed": None, "runs_30d": 0, "cost_30d": 0.0})
        t["routines"] += 1
        t["paused"] += 1 if r["paused"] else 0
        t["live"] += 1 if r["id"] in live else 0
        t["runs_30d"] += p["runs_30d"]
        t["cost_30d"] = round(t["cost_30d"] + p["cost_30d"], 4)
        if p["failed"] and not r["paused"]:
            t["failed"] += 1
            if not t["last_failed"] or x["at"] > t["last_failed"]["at"]:
                t["last_failed"] = {"id": r["id"], "name": r["name"], "at": x["at"], "reason": x["reason"], "session": x["session"]}
    return {"teams": teams, "routines": {str(k): v for k, v in per.items()}}


def import_files(con, files):
    """Rebuild log tables from their files, one transaction: the files are complete
    (each writer appends to its file first), so the table matches them exactly.
    files: [(table, path, kind)] with kind "jsonl", "array" (lessons) or "object" (resolutions)."""
    con.execute("BEGIN IMMEDIATE")
    try:
        counts = {}
        for tbl, path, kind in files:
            if not os.path.exists(path):
                counts[tbl] = 0
                continue
            if kind == "dir":
                con.execute("DELETE FROM sessions")
                recs = _session_files(path)
                con.executemany("INSERT INTO sessions (key, data) VALUES (?, json(?))", recs)
                counts[tbl] = len(recs)
                continue
            if tbl == "llm_calls":
                con.execute("DELETE FROM llm_daily")  # its trigger rebuilds it from the calls
            if tbl in ("errors", "error_resolutions", "llm_calls", "mcp_calls", "runs", "job_costs", "passes", "lessons"):
                con.execute(f"DELETE FROM {tbl}")
            if kind == "jsonl":
                recs = [ln for ln in open(path, errors="replace") if ln.strip()]
            elif kind == "array":
                recs = [json.dumps(r) for r in json.load(open(path))]
            else:
                recs = [json.dumps({"sig": k, **v}) for k, v in json.load(open(path)).items()]
            con.executemany("INSERT INTO ingest (tbl, j) VALUES (?, ?)", [(tbl, r) for r in recs if _is_json(r)])
            counts[tbl] = len(recs)
        con.execute("COMMIT")
        return counts
    except Exception:
        con.execute("ROLLBACK")
        raise


_MEDIA = re.compile(r"^[A-Za-z0-9._-]{1,120}[.](png|jpe?g|gif|webp|mp4|webm)$")


def session_row(rec, d):
    """A session as the page shows it when no live agent is attached: the record,
    its request (the first 300 bytes of the prompt) and the media the host kept."""
    key = rec.get("key", "")
    try:
        with open(os.path.join(d, key + ".prompt.md"), "rb") as f:
            req = f.read(300).decode("utf-8", "ignore").rstrip("\n")   # as $(head -c 300) did
    except OSError:
        req = ""
    md = os.path.join(d, key + ".media")
    media = []
    if os.path.isdir(md):
        media = sorted(({"at": int(os.path.getmtime(os.path.join(md, m))), "name": m} for m in os.listdir(md) if _MEDIA.match(m)),
                       key=lambda x: (x["at"], x["name"]))
    return {**rec, "agent": None, "agent_alive": False, "request": req, "media": media}


_LIVE = {"starting", "active", "wrapping"}


def is_over_test(rec):
    """A dev bot or dry-run session that is over: the session pages leave it out, as Stats does."""
    return rec.get("state") not in _LIVE and (rec.get("owner") == "U-DRYRUN" or rec.get("env") == "dev")


def sessions_since(con, since, d, limit=200):
    """{cursor, rows}: the sessions written after change `since`, as session_row()s, and
    {key, deleted} for one that is gone. With since None, only the cursor to start from."""
    cur = con.execute("SELECT coalesce(max(version), 0) FROM changes").fetchone()[0]
    if since is None:
        return {"cursor": cur, "rows": []}
    rows = []
    for (key,) in con.execute("SELECT DISTINCT key FROM changes WHERE tbl = 'sessions' AND version > ? AND version <= ? LIMIT ?",
                              (since, cur, limit)).fetchall():
        r = con.execute("SELECT data FROM sessions WHERE key = ?", (key,)).fetchone()
        rec = json.loads(r[0]) if r else None
        rows.append(session_row(rec, d) if rec and not is_over_test(rec) else {"key": key, "deleted": True})
    return {"cursor": cur, "rows": rows}


def usage_by_model(con, run):
    """One run's LLM calls by model: calls, the four token kinds and the cost, costliest first."""
    return rows(con, """SELECT model, count(*) AS calls, coalesce(sum(input_tokens), 0) AS input,
        coalesce(sum(cache_read_input_tokens), 0) AS cache_read, coalesce(sum(cache_creation_input_tokens), 0) AS cache_write,
        coalesce(sum(output_tokens), 0) AS output, round(coalesce(sum(usd), 0), 4) AS usd
        FROM llm_calls WHERE run = ? GROUP BY model ORDER BY usd DESC""", (run,))


def _session_files(d):
    """(key, text) of every readable session record in d."""
    out = []
    for n in sorted(os.listdir(d)):
        if n.startswith("agent-") and n.endswith(".json"):
            try:
                t = open(os.path.join(d, n)).read()
            except OSError:
                continue
            if _is_json(t):
                out.append((n[:-5], t))
    return out


def sessions_differ(con, d):
    """How many session records differ between the directory and the table, either way."""
    files = {k: json.loads(t) for k, t in _session_files(d)}
    rows = {r["key"]: json.loads(r["data"]) for r in con.execute("SELECT key, data FROM sessions")}
    return sum(1 for k in files.keys() | rows.keys() if files.get(k) != rows.get(k))


def _is_json(s):
    try:
        json.loads(s)
        return True
    except ValueError:
        return False


ID_LIST = re.compile(r"^[UW][A-Z0-9]{6,}(,[UW][A-Z0-9]{6,}){0,199}$")


def people(con, q, env="live", most=20):
    """For the people picker of a team's Settings (admins only): the people whose name, handle or email holds q,
    or, when q is a comma list of member IDs, those people. at is the time of the bot's last list (None: no list)."""
    at = con.execute("SELECT max(at) FROM slack_users WHERE env = ?", (env,)).fetchone()[0]
    if ID_LIST.match(q):
        ids = q.split(",")
        rows = con.execute(f"SELECT id, name, handle, email FROM slack_users WHERE env = ? AND id IN ({','.join('?' * len(ids))})", (env, *ids))
    else:
        like = "%" + q.lower().replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"
        rows = con.execute("SELECT id, name, handle, email FROM slack_users WHERE env = ? AND (lower(name) LIKE ? ESCAPE '\\' OR lower(handle) LIKE ? ESCAPE '\\'"
                           " OR email LIKE ? ESCAPE '\\') ORDER BY lower(name) LIMIT ?", (env, like, like, like, most))
    return {"at": at, "people": [dict(r) for r in rows]}
