-- Schema 3: llm_calls.thread, the Slack thread (channel:ts) of the run, from the proxy's usage line.
-- Rows from before it get the thread from the session's record; a quick answer shares its session's hex.
ALTER TABLE llm_calls ADD COLUMN thread TEXT;
CREATE INDEX llm_calls_thread ON llm_calls(thread);
DROP TRIGGER IF EXISTS ingest_llm;
CREATE TRIGGER ingest_llm INSTEAD OF INSERT ON ingest WHEN NEW.tbl = 'llm_calls' BEGIN
  INSERT INTO llm_calls (at, run, thread, model, usd, usd_cache_write, input_tokens, output_tokens, cache_creation_input_tokens, cache_read_input_tokens)
  SELECT j->>'at', j->>'run', j->>'thread', j->>'model', j->>'usd', j->>'usd_cache_write', j->>'input_tokens', j->>'output_tokens', j->>'cache_creation_input_tokens', j->>'cache_read_input_tokens'
  FROM (SELECT json(NEW.j) AS j);
END;
UPDATE llm_calls SET thread = (SELECT data->>'thread' FROM sessions WHERE key = 'agent-' || substr(llm_calls.run, instr(llm_calls.run, '-') + 1))
  WHERE thread IS NULL AND (run LIKE 'agent-%' OR run LIKE 'ask-%');
