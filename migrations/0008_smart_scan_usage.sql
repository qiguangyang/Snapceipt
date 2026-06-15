-- Per-user, per-month count of LLM ("smart scan") extractions, for the free/Pro cap.
-- Server-only; NEVER synced.
CREATE TABLE smart_scan_usage (
  user_id    TEXT    NOT NULL,
  period     TEXT    NOT NULL,            -- 'YYYY-MM' (UTC)
  count      INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, period)
);
