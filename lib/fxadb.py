"""The controller's SQLite store, for the Python writers and readers: the
dashboard, the LLM proxy and the MCP gateway. lib/db.sh owns the schema
(`fxa-sandbox-ctl db init`); this only connects. Use bound parameters, never
string formatting, for any value.
"""
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


def rows(con, sql, params=()):
    """The rows of one query as plain dicts, ready for json.dumps."""
    return [dict(r) for r in con.execute(sql, params)]
