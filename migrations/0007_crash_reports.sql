-- 0007_crash_reports.sql — iOS MetricKit crash/hang diagnostics ingest.
-- Server-only: NEVER added to SYNCABLE_TABLES (src/lib/syncTables.ts) — a device
-- posts its own diagnostics; they are never pulled back. Scoped to (user_id,
-- device_id) for triage. payload is the raw MXDiagnostic dictionary stored as JSON.
CREATE TABLE crash_reports (
  id           TEXT PRIMARY KEY,
  user_id      TEXT NOT NULL REFERENCES users(id),
  device_id    TEXT NOT NULL,
  kind         TEXT NOT NULL CHECK (kind IN ('crash','hang')),
  app_version  TEXT NOT NULL,
  os_version   TEXT NOT NULL,
  device_model TEXT NOT NULL,
  occurred_at  INTEGER NOT NULL,
  payload      TEXT NOT NULL,
  created_at   INTEGER NOT NULL
);
CREATE INDEX ix_crash_user      ON crash_reports(user_id);
CREATE INDEX ix_crash_created   ON crash_reports(created_at);
CREATE INDEX ix_crash_kind_ver  ON crash_reports(kind, app_version);
