"""The controller's SQLite store, for the Python writers and readers: the
dashboard, the LLM proxy and the MCP gateway. lib/db.sh owns the schema
(`fxa-sandbox-ctl db init`); this only connects. Use bound parameters, never
string formatting, for any value.
"""
import json
import os
import sqlite3

PATH = os.environ.get("FXA_DB") or os.path.expanduser("~/.claude/state/fxa.db")


def connect(path=None, readonly=False):
    """A connection that waits up to 5 s for a writer, as every other client does."""
    p = path or PATH
    con = sqlite3.connect(f"file:{p}?mode=ro" if readonly else p, uri=readonly, timeout=5, isolation_level=None)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA busy_timeout = 5000")
    return con


_CON = None


def ingest(tbl, obj):
    """One log record into the store, mapped by the ingest triggers. Never raises:
    the caller's file is the fallback while the store proves itself."""
    global _CON
    try:
        if _CON is None:
            if not os.path.exists(PATH):
                return  # no store here (a test, or a host without db init): do not create an empty one
            _CON = connect()
        _CON.execute("INSERT INTO ingest (tbl, j) VALUES (?, ?)", (tbl, obj if isinstance(obj, str) else json.dumps(obj)))
    except Exception:  # noqa: BLE001 - the file write already happened
        _CON = None


def rows(con, sql, params=()):
    """The rows of one query as plain dicts, ready for json.dumps."""
    return [dict(r) for r in con.execute(sql, params)]


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
