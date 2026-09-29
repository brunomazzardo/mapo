-- Agent tabs resume their Claude session after a daemon restart (R-AG-7, PLAN T2.5).
ALTER TABLE tabs ADD COLUMN session_id TEXT;
