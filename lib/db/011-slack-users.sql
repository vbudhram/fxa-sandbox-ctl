-- Schema 11: the people in each bot's Slack workspace, for the people picker of a team's Settings. A bot writes
-- its whole list through ingest, and the write replaces the rows of its env. No bot and no deactivated account.
CREATE TABLE slack_users (env TEXT NOT NULL CHECK (env IN ('live', 'dev')), id TEXT NOT NULL, name TEXT NOT NULL,
  handle TEXT NOT NULL, email TEXT NOT NULL, at INTEGER NOT NULL, PRIMARY KEY (env, id));
CREATE TRIGGER ingest_slack_users INSTEAD OF INSERT ON ingest WHEN NEW.tbl = 'slack_users' AND json_extract(NEW.j, '$.env') IN ('live', 'dev') BEGIN
  DELETE FROM slack_users WHERE env = json_extract(NEW.j, '$.env');
  INSERT OR IGNORE INTO slack_users (env, id, name, handle, email, at)
  SELECT json_extract(NEW.j, '$.env'), u.value->>'id', u.value->>'name', coalesce(u.value->>'handle', ''), lower(coalesce(u.value->>'email', '')), json_extract(NEW.j, '$.at')
  FROM json_each(NEW.j, '$.users') u WHERE u.value->>'id' GLOB '[UW][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]*' AND u.value->>'name' IS NOT NULL;
END;
