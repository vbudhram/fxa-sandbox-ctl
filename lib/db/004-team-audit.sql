-- Schema 4: team_audit, one row for each write to a team record (lib/teams.sh): who, what, and the
-- generations before and after. changed names the top-level keys only; a record holds no secret value.
CREATE TABLE team_audit (id INTEGER PRIMARY KEY, at INTEGER NOT NULL, actor TEXT NOT NULL, team TEXT NOT NULL,
  action TEXT NOT NULL, old_gen TEXT, new_gen TEXT, changed TEXT);
CREATE INDEX team_audit_team ON team_audit(team, at);
