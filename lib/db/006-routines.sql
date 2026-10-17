-- Schema 6: routines (epic i168, design 2026-10-17-routines.md). A routine is a team's scheduled prompt; data
-- holds its validated config (lib/routine.py). routine_runs has one row for each (routine, period): the
-- UNIQUE key is what keeps two ticks, a retry or a DST change from starting one period twice.
CREATE TABLE routines (id INTEGER PRIMARY KEY, team TEXT NOT NULL, data TEXT NOT NULL, env TEXT NOT NULL DEFAULT 'live',
  paused INTEGER NOT NULL DEFAULT 0, version INTEGER NOT NULL DEFAULT 1, created_by TEXT, updated_by TEXT, updated_at INTEGER);
CREATE INDEX routines_team ON routines(team);
CREATE TABLE routine_runs (id INTEGER PRIMARY KEY, routine_id INTEGER NOT NULL, period TEXT NOT NULL, trigger TEXT,
  actor TEXT, state TEXT NOT NULL DEFAULT 'claimed', reason TEXT, session TEXT, thread TEXT, pr_url TEXT, cost_usd REAL,
  heads TEXT, config TEXT, report TEXT, posted INTEGER NOT NULL DEFAULT 0, started_at INTEGER, ended_at INTEGER,
  UNIQUE(routine_id, period));
CREATE INDEX routine_runs_routine ON routine_runs(routine_id, id);
CREATE TABLE routine_tick (id INTEGER PRIMARY KEY CHECK (id = 1), at INTEGER NOT NULL);
