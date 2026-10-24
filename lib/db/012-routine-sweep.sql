-- Schema 12: the dependency PR sweep of an on='pr-label' routine. swept_at is the end of its last full sweep, and
-- sweep_pr the last PR number done when a sweep ran out of time, so the next tick continues after it.
ALTER TABLE routines ADD COLUMN swept_at INTEGER;
ALTER TABLE routines ADD COLUMN sweep_pr INTEGER;
-- A fix row (heads.fix set) that ends with no result frees its PR head for a new request: its period
-- 'pr-<n>-<sha>' becomes 'pr-<n>-<sha>-x<id>', for every writer that ends a row. Revert: DROP TRIGGER.
CREATE TRIGGER routine_runs_fix_free AFTER UPDATE OF state ON routine_runs
  WHEN NEW.state IN ('failed', 'stopped', 'skipped') AND json_extract(NEW.heads, '$.fix') IS NOT NULL AND NEW.period NOT LIKE '%-x%'
BEGIN
  UPDATE routine_runs SET period = NEW.period || '-x' || NEW.id WHERE id = NEW.id;
END;
