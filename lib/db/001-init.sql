-- Schema 1. See ai/docs/design-docs/2026-10-02-sqlite-state-design.md.
-- Records live here; blobs (conversation archives, patches, media, logs) stay files.

CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v);

-- A session keeps its flexible JSON shape; the fields the dashboard filters on are generated columns.
CREATE TABLE IF NOT EXISTS sessions (
  key TEXT PRIMARY KEY,
  data TEXT NOT NULL CHECK (json_valid(data)),
  state TEXT GENERATED ALWAYS AS (json_extract(data, '$.state')) VIRTUAL,
  created REAL GENERATED ALWAYS AS (json_extract(data, '$.created')) VIRTUAL,
  last_activity REAL GENERATED ALWAYS AS (json_extract(data, '$.last_activity')) VIRTUAL,
  owner TEXT GENERATED ALWAYS AS (json_extract(data, '$.owner')) VIRTUAL);
CREATE INDEX IF NOT EXISTS sessions_state ON sessions(state, created);
CREATE INDEX IF NOT EXISTS sessions_created ON sessions(created);

CREATE TABLE IF NOT EXISTS threads (id TEXT PRIMARY KEY, data TEXT NOT NULL CHECK (json_valid(data)));
CREATE TABLE IF NOT EXISTS history (id INTEGER PRIMARY KEY, key TEXT NOT NULL, at REAL, role TEXT, text TEXT);
CREATE INDEX IF NOT EXISTS history_key ON history(key, id);
CREATE TABLE IF NOT EXISTS turns (key TEXT NOT NULL, n INTEGER, start_at REAL NOT NULL, end_at REAL, secs REAL, cost REAL, tokens INTEGER, PRIMARY KEY (key, start_at));
CREATE TABLE IF NOT EXISTS boots (key TEXT NOT NULL, at REAL, backend TEXT, total REAL, steps TEXT);

CREATE TABLE IF NOT EXISTS errors (id INTEGER PRIMARY KEY, at TEXT, source TEXT, kind TEXT, key TEXT, "where" TEXT, message TEXT, log TEXT, sig TEXT);
CREATE INDEX IF NOT EXISTS errors_sig ON errors(sig, at);
CREATE TABLE IF NOT EXISTS error_resolutions (sig TEXT PRIMARY KEY, at TEXT, note TEXT);
CREATE TABLE IF NOT EXISTS lessons (id TEXT PRIMARY KEY, at TEXT, session TEXT, text TEXT, why TEXT, status TEXT, decided_at TEXT);

CREATE TABLE IF NOT EXISTS llm_calls (id INTEGER PRIMARY KEY, at TEXT, run TEXT, model TEXT, usd REAL, usd_cache_write REAL,
  input INTEGER, output INTEGER, cache_write INTEGER, cache_read INTEGER);
CREATE INDEX IF NOT EXISTS llm_calls_run ON llm_calls(run, at);
CREATE INDEX IF NOT EXISTS llm_calls_at ON llm_calls(at);
CREATE TABLE IF NOT EXISTS llm_daily (day TEXT, model TEXT, calls INTEGER, usd REAL, usd_cache_write REAL, PRIMARY KEY (day, model));
CREATE TABLE IF NOT EXISTS mcp_calls (id INTEGER PRIMARY KEY, at REAL, run TEXT, server TEXT, tool TEXT, ms INTEGER, ok INTEGER);
CREATE TABLE IF NOT EXISTS runs (id INTEGER PRIMARY KEY, recorded_at TEXT, issue TEXT, kind TEXT, model TEXT, cost_usd REAL, wall_seconds REAL, data TEXT);
CREATE INDEX IF NOT EXISTS runs_issue ON runs(issue, recorded_at);
CREATE TABLE IF NOT EXISTS job_costs (id INTEGER PRIMARY KEY, at TEXT, job TEXT, cost_usd REAL, turns INTEGER, duration_ms INTEGER);
CREATE TABLE IF NOT EXISTS passes (id INTEGER PRIMARY KEY, at INTEGER, queued INTEGER, awaiting INTEGER, inflight INTEGER, work INTEGER, data TEXT);

-- What moved, for the dashboard's deltas: one row per changed record, the version is the rowid.
CREATE TABLE IF NOT EXISTS changes (version INTEGER PRIMARY KEY, at REAL NOT NULL DEFAULT (unixepoch('subsec')), tbl TEXT NOT NULL, key TEXT);
CREATE INDEX IF NOT EXISTS changes_tbl ON changes(tbl, version);

-- A day's LLM spend per model, kept on insert, so stats read a few rows at any history size.
CREATE TRIGGER IF NOT EXISTS llm_calls_daily AFTER INSERT ON llm_calls BEGIN
  INSERT INTO llm_daily (day, model, calls, usd, usd_cache_write) VALUES (substr(NEW.at, 1, 10), coalesce(NEW.model, ''), 1, coalesce(NEW.usd, 0), coalesce(NEW.usd_cache_write, 0))
  ON CONFLICT (day, model) DO UPDATE SET calls = calls + 1, usd = usd + excluded.usd, usd_cache_write = usd_cache_write + excluded.usd_cache_write;
END;

CREATE TRIGGER IF NOT EXISTS sessions_ins AFTER INSERT ON sessions BEGIN INSERT INTO changes (tbl, key) VALUES ('sessions', NEW.key); END;
CREATE TRIGGER IF NOT EXISTS sessions_upd AFTER UPDATE ON sessions BEGIN INSERT INTO changes (tbl, key) VALUES ('sessions', NEW.key); END;
CREATE TRIGGER IF NOT EXISTS sessions_del AFTER DELETE ON sessions BEGIN INSERT INTO changes (tbl, key) VALUES ('sessions', OLD.key); END;
CREATE TRIGGER IF NOT EXISTS history_ins AFTER INSERT ON history BEGIN INSERT INTO changes (tbl, key) VALUES ('history', NEW.key); END;
CREATE TRIGGER IF NOT EXISTS errors_ins AFTER INSERT ON errors BEGIN INSERT INTO changes (tbl, key) VALUES ('errors', NEW.sig); END;
CREATE TRIGGER IF NOT EXISTS error_res_chg AFTER INSERT ON error_resolutions BEGIN INSERT INTO changes (tbl, key) VALUES ('errors', NEW.sig); END;
CREATE TRIGGER IF NOT EXISTS lessons_ins AFTER INSERT ON lessons BEGIN INSERT INTO changes (tbl, key) VALUES ('lessons', NEW.id); END;
CREATE TRIGGER IF NOT EXISTS lessons_upd AFTER UPDATE ON lessons BEGIN INSERT INTO changes (tbl, key) VALUES ('lessons', NEW.id); END;
CREATE TRIGGER IF NOT EXISTS runs_ins AFTER INSERT ON runs BEGIN INSERT INTO changes (tbl, key) VALUES ('runs', NEW.issue); END;
CREATE TRIGGER IF NOT EXISTS passes_ins AFTER INSERT ON passes BEGIN INSERT INTO changes (tbl, key) VALUES ('passes', NULL); END;
CREATE TRIGGER IF NOT EXISTS llm_daily_chg AFTER UPDATE ON llm_daily BEGIN INSERT INTO changes (tbl, key) VALUES ('llm', NEW.day); END;
