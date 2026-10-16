-- Schema 5: llm_calls.team, the team whose run made the call (the proxy's usage line), for spend by team.
ALTER TABLE llm_calls ADD COLUMN team TEXT;
CREATE INDEX llm_calls_team ON llm_calls(team, at);
DROP TRIGGER IF EXISTS ingest_llm;
CREATE TRIGGER ingest_llm INSTEAD OF INSERT ON ingest WHEN NEW.tbl = 'llm_calls' BEGIN
  INSERT INTO llm_calls (at, run, thread, team, model, usd, usd_cache_write, input_tokens, output_tokens, cache_creation_input_tokens, cache_read_input_tokens)
  SELECT j->>'at', j->>'run', j->>'thread', j->>'team', j->>'model', j->>'usd', j->>'usd_cache_write', j->>'input_tokens', j->>'output_tokens', j->>'cache_creation_input_tokens', j->>'cache_read_input_tokens'
  FROM (SELECT json(NEW.j) AS j);
END;
