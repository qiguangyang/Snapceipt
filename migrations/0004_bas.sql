-- 0004_bas.sql — BAS-ready export GST-treatment columns (spec §4.1).
-- Pure ADD COLUMN with constant defaults (non-rewriting in SQLite/D1). Prod is
-- live at 0003; this applies via `wrangler d1 migrations apply --remote` and both
-- test harnesses apply it in order. No CHECK-constraint changes (the emailed BAS
-- pack reuses email_outbox.kind='export_accountant').
ALTER TABLE transactions ADD COLUMN gst_free   INTEGER NOT NULL DEFAULT 0;  -- 0/1
ALTER TABLE transactions ADD COLUMN capital    INTEGER NOT NULL DEFAULT 0;  -- 0/1, expense-only meaning
ALTER TABLE transactions ADD COLUMN gst_source TEXT;                        -- 'printed'|'derived'|'manual'|NULL
ALTER TABLE categories   ADD COLUMN gst_free_default INTEGER NOT NULL DEFAULT 0;
