-- Schema 8: one heartbeat for each env. The dev and live bots share this store, so one row let a running dev
-- bot hide a live bot that does not tick. routine_tick stays for code that predates this schema.
CREATE TABLE routine_tick_env (env TEXT PRIMARY KEY CHECK (env IN ('live', 'dev')), at INTEGER NOT NULL);
