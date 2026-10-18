-- Schema 7: routines.saved_at, the time of the routine's last create or edit (not a pause or resume): the tick
-- runs no period whose time is before it, so a routine saved after today's time first runs at its next one.
ALTER TABLE routines ADD COLUMN saved_at INTEGER;
-- The backfill takes updated_at, which may be the time of a pause or resume: at worst a routine skips one
-- period it could have run.
UPDATE routines SET saved_at = updated_at;
