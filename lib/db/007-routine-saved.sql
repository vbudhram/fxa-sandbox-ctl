-- Schema 7: routines.saved_at, the time of the routine's last create or edit (not a pause or resume): the tick
-- runs no period whose time is before it, so a routine saved after today's time first runs at its next one.
ALTER TABLE routines ADD COLUMN saved_at INTEGER;
UPDATE routines SET saved_at = updated_at;
