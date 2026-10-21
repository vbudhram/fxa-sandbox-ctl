-- Schema 10: the Slack channels each bot is in, for the channel picker of the routine form. The dev and live
-- bots are two Slack apps in other channels, so each env has its own rows. A bot writes its whole list through
-- ingest, and the write replaces the rows of its env.
CREATE TABLE slack_channels (env TEXT NOT NULL CHECK (env IN ('live', 'dev')), id TEXT NOT NULL, name TEXT NOT NULL,
  private INTEGER NOT NULL, shared INTEGER NOT NULL, at INTEGER NOT NULL, PRIMARY KEY (env, id));
CREATE TRIGGER ingest_slack_channels INSTEAD OF INSERT ON ingest WHEN NEW.tbl = 'slack_channels' AND json_extract(NEW.j, '$.env') IN ('live', 'dev') BEGIN
  DELETE FROM slack_channels WHERE env = json_extract(NEW.j, '$.env');
  INSERT OR IGNORE INTO slack_channels (env, id, name, private, shared, at)
  SELECT json_extract(NEW.j, '$.env'), c.value->>'id', c.value->>'name', coalesce(c.value->>'private', 0) != 0, coalesce(c.value->>'shared', 0) != 0, json_extract(NEW.j, '$.at')
  FROM json_each(NEW.j, '$.channels') c WHERE c.value->>'id' GLOB '[CG][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]*' AND c.value->>'name' IS NOT NULL;
END;
