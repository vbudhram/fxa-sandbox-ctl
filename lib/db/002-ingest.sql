-- Schema 2: one way in for the logs. Every writer, in bash, Python or Node, does
--   INSERT INTO ingest (tbl, j) VALUES ('<table>', '<the JSON line it also appends to its file>')
-- and a trigger maps the JSON fields to the table's columns. The mapping lives here, once.

-- The columns follow the JSON field names the writers already use (both tables are empty at schema 1).
DROP TABLE IF EXISTS llm_calls;
CREATE TABLE llm_calls (id INTEGER PRIMARY KEY, at TEXT, run TEXT, model TEXT, usd REAL, usd_cache_write REAL,
  input_tokens INTEGER, output_tokens INTEGER, cache_creation_input_tokens INTEGER, cache_read_input_tokens INTEGER);
CREATE INDEX llm_calls_run ON llm_calls(run, at);
CREATE INDEX llm_calls_at ON llm_calls(at);
CREATE TRIGGER llm_calls_daily AFTER INSERT ON llm_calls BEGIN
  INSERT INTO llm_daily (day, model, calls, usd, usd_cache_write) VALUES (substr(NEW.at, 1, 10), coalesce(NEW.model, ''), 1, coalesce(NEW.usd, 0), coalesce(NEW.usd_cache_write, 0))
  ON CONFLICT (day, model) DO UPDATE SET calls = calls + 1, usd = usd + excluded.usd, usd_cache_write = usd_cache_write + excluded.usd_cache_write;
END;
CREATE TRIGGER IF NOT EXISTS llm_daily_ins AFTER INSERT ON llm_daily BEGIN INSERT INTO changes (tbl, key) VALUES ('llm', NEW.day); END;

DROP TABLE IF EXISTS mcp_calls;
CREATE TABLE mcp_calls (id INTEGER PRIMARY KEY, at TEXT, run TEXT, connector TEXT, tool TEXT, outcome TEXT, ms INTEGER, bytes INTEGER, args TEXT);
CREATE INDEX mcp_calls_at ON mcp_calls(at);

ALTER TABLE job_costs ADD COLUMN is_error INTEGER;
CREATE TRIGGER IF NOT EXISTS job_costs_ins AFTER INSERT ON job_costs BEGIN INSERT INTO changes (tbl, key) VALUES ('job_costs', NEW.job); END;

CREATE VIEW ingest AS SELECT NULL AS tbl, NULL AS j;

CREATE TRIGGER ingest_errors INSTEAD OF INSERT ON ingest WHEN NEW.tbl = 'errors' BEGIN
  INSERT INTO errors (at, source, kind, key, "where", message, log, sig)
  SELECT j->>'at', j->>'source', j->>'kind', j->>'key', j->>'where', j->>'message', j->>'log', j->>'sig' FROM (SELECT json(NEW.j) AS j);
END;
CREATE TRIGGER ingest_llm INSTEAD OF INSERT ON ingest WHEN NEW.tbl = 'llm_calls' BEGIN
  INSERT INTO llm_calls (at, run, model, usd, usd_cache_write, input_tokens, output_tokens, cache_creation_input_tokens, cache_read_input_tokens)
  SELECT j->>'at', j->>'run', j->>'model', j->>'usd', j->>'usd_cache_write', j->>'input_tokens', j->>'output_tokens', j->>'cache_creation_input_tokens', j->>'cache_read_input_tokens'
  FROM (SELECT json(NEW.j) AS j);
END;
CREATE TRIGGER ingest_mcp INSTEAD OF INSERT ON ingest WHEN NEW.tbl = 'mcp_calls' BEGIN
  INSERT INTO mcp_calls (at, run, connector, tool, outcome, ms, bytes, args)
  SELECT j->>'at', j->>'run', j->>'connector', j->>'tool', j->>'outcome', j->>'ms', j->>'bytes', j->>'args' FROM (SELECT json(NEW.j) AS j);
END;
CREATE TRIGGER ingest_runs INSTEAD OF INSERT ON ingest WHEN NEW.tbl = 'runs' BEGIN
  INSERT INTO runs (recorded_at, issue, kind, model, cost_usd, wall_seconds, data)
  SELECT j->>'recorded_at', j->>'issue', j->>'kind', j->>'model', j->>'cost_usd', j->>'wall_seconds', j FROM (SELECT json(NEW.j) AS j);
END;
CREATE TRIGGER ingest_job_costs INSTEAD OF INSERT ON ingest WHEN NEW.tbl = 'job_costs' BEGIN
  INSERT INTO job_costs (at, job, cost_usd, turns, duration_ms, is_error)
  SELECT j->>'at', j->>'job', j->>'cost_usd', j->>'turns', j->>'duration_ms', j->>'is_error' FROM (SELECT json(NEW.j) AS j);
END;
CREATE TRIGGER ingest_passes INSTEAD OF INSERT ON ingest WHEN NEW.tbl = 'passes' BEGIN
  INSERT INTO passes (at, queued, awaiting, inflight, work, data)
  SELECT j->>'at', j->>'queued', j->>'awaiting', j->>'inflight', j->>'work', j FROM (SELECT json(NEW.j) AS j);
END;
-- A lesson is a record that changes: insert, or update its status and text.
CREATE TRIGGER ingest_lessons INSTEAD OF INSERT ON ingest WHEN NEW.tbl = 'lessons' BEGIN
  INSERT INTO lessons (id, at, session, text, why, status, decided_at)
  SELECT j->>'id', j->>'at', j->>'session', j->>'text', j->>'why', j->>'status', j->>'decided_at' FROM (SELECT json(NEW.j) AS j) WHERE true
  ON CONFLICT (id) DO UPDATE SET text = excluded.text, why = excluded.why, status = excluded.status, decided_at = excluded.decided_at;
END;
CREATE TRIGGER ingest_resolution INSTEAD OF INSERT ON ingest WHEN NEW.tbl = 'error_resolutions' BEGIN
  INSERT INTO error_resolutions (sig, at, note) SELECT j->>'sig', j->>'at', j->>'note' FROM (SELECT json(NEW.j) AS j) WHERE true
  ON CONFLICT (sig) DO UPDATE SET at = excluded.at, note = excluded.note;
END;
