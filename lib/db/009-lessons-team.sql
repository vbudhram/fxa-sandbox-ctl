-- Schema 9: lessons.team, the team whose session proposed the lesson. A runner gets only its own team's
-- approved lessons, and a private team's lessons stay off the shared queue. Every lesson so far came from FxA.
ALTER TABLE lessons ADD COLUMN team TEXT;
UPDATE lessons SET team = 'fxa' WHERE team IS NULL;
DROP TRIGGER IF EXISTS ingest_lessons;
CREATE TRIGGER ingest_lessons INSTEAD OF INSERT ON ingest WHEN NEW.tbl = 'lessons' BEGIN
  INSERT INTO lessons (id, at, session, team, text, why, status, decided_at)
  SELECT j->>'id', j->>'at', j->>'session', coalesce(j->>'team', 'fxa'), j->>'text', j->>'why', j->>'status', j->>'decided_at' FROM (SELECT json(NEW.j) AS j) WHERE true
  ON CONFLICT (id) DO UPDATE SET text = excluded.text, why = excluded.why, status = excluded.status, decided_at = excluded.decided_at;
END;
