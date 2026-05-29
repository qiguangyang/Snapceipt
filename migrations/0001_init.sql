-- 0001_init.sql — foundation placeholder.
-- The full domain schema (users, sessions, transactions, processed_mutations, …)
-- is added by the schema task. This single table exists so the Vitest harness
-- (readD1Migrations + applyD1Migrations) has a real migration to apply, and so
-- `wrangler d1 migrations apply` has a non-empty initial migration.
CREATE TABLE IF NOT EXISTS _meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

INSERT OR IGNORE INTO _meta (key, value) VALUES ('schema_version', '0001');
