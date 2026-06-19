-- 0009_invoices_ar.sql — Invoices + accounts-receivable (spec §3, §4.1, §4.5).
-- Forward-only. Additive new tables + two additive quotes columns; the email_outbox
-- rebuild adds 'invoice_send' to the kind CHECK (SQLite cannot ALTER a CHECK, so the
-- table is recreated: copy rows, drop, rename, recreate indexes). ids = UUIDv7 TEXT.
-- Money = INTEGER cents. Timestamps = INTEGER epoch ms. Dates = TEXT 'YYYY-MM-DD'.
-- Syncable tables carry: id, user_id, created_at, updated_at, deleted_at, rev, last_edited_device_id.
PRAGMA foreign_keys = OFF;

-- =========================================================================
-- invoices — issued tax invoices (synced via the generic /sync upsert).
-- status: draft (editable) | issued (number + PDF + dates minted) | void.
-- number is minted on issue only; quote_id links back to the origin quote.
-- =========================================================================
CREATE TABLE invoices (
  id                    TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL REFERENCES users(id),
  profile_id            TEXT NOT NULL REFERENCES profiles(id),
  number                TEXT,
  quote_id              TEXT REFERENCES quotes(id),
  client_name           TEXT,
  client_email          TEXT,
  gst_enabled           INTEGER NOT NULL DEFAULT 1,
  gst_inclusive         INTEGER NOT NULL DEFAULT 0,
  subtotal_cents        INTEGER NOT NULL DEFAULT 0,
  gst_cents             INTEGER NOT NULL DEFAULT 0,
  total_cents           INTEGER NOT NULL DEFAULT 0,
  currency              TEXT NOT NULL DEFAULT 'AUD',
  status                TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','issued','void')),
  issue_date            TEXT,
  due_date              TEXT,
  issued_at             INTEGER,
  pdf_r2_key            TEXT,
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  deleted_at            INTEGER,
  rev                   INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id TEXT
);
CREATE INDEX ix_invoice_user_updated   ON invoices(user_id, updated_at);
CREATE INDEX ix_invoice_profile_status ON invoices(profile_id, status) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX ux_invoice_number  ON invoices(profile_id, number) WHERE number IS NOT NULL AND deleted_at IS NULL;

-- =========================================================================
-- invoice_line_items — clone of quote_line_items (line_total_cents generated).
-- =========================================================================
CREATE TABLE invoice_line_items (
  id                    TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL REFERENCES users(id),
  invoice_id            TEXT NOT NULL REFERENCES invoices(id),
  description           TEXT NOT NULL,
  quantity              INTEGER NOT NULL DEFAULT 1,
  unit_price_cents      INTEGER NOT NULL,
  line_total_cents      INTEGER GENERATED ALWAYS AS (quantity * unit_price_cents) STORED,
  sort_order            INTEGER NOT NULL DEFAULT 0,
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  deleted_at            INTEGER,
  rev                   INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id TEXT
);
CREATE INDEX ix_ili_invoice      ON invoice_line_items(invoice_id);
CREATE INDEX ix_ili_user_updated ON invoice_line_items(user_id, updated_at);

-- =========================================================================
-- payments — multiple rows per invoice; payment state is DERIVED, never stored.
-- =========================================================================
CREATE TABLE payments (
  id                    TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL REFERENCES users(id),
  invoice_id            TEXT NOT NULL REFERENCES invoices(id),
  amount_cents          INTEGER NOT NULL,
  paid_on               TEXT NOT NULL,
  method                TEXT,
  note                  TEXT,
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  deleted_at            INTEGER,
  rev                   INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id TEXT
);
CREATE INDEX ix_payment_invoice      ON payments(invoice_id);
CREATE INDEX ix_payment_user_updated ON payments(user_id, updated_at);

-- =========================================================================
-- invoice_counters — server-only per-PROFILE INV-#### sequence. NOT synced. The
-- issue route increments next_seq atomically (INSERT … ON CONFLICT … RETURNING) so
-- concurrent issues never collide; invoices.ux_invoice_number is the unique backstop.
-- =========================================================================
CREATE TABLE invoice_counters (
  profile_id TEXT PRIMARY KEY REFERENCES profiles(id),
  next_seq   INTEGER NOT NULL
);

-- =========================================================================
-- quotes — additive columns: the persisted quote-PDF R2 key (re-shareable from
-- history) and the one-to-one origin link to the converted invoice. Pure ADD
-- COLUMN (non-rewriting in SQLite/D1).
-- =========================================================================
ALTER TABLE quotes ADD COLUMN pdf_r2_key TEXT;
ALTER TABLE quotes ADD COLUMN invoice_id TEXT;

-- =========================================================================
-- email_outbox — rebuild to add 'invoice_send' to the kind CHECK. SQLite cannot
-- ALTER a CHECK, so recreate the table, copy rows, drop, rename, recreate indexes.
-- =========================================================================
CREATE TABLE email_outbox_new (
  id            TEXT PRIMARY KEY,
  user_id       TEXT REFERENCES users(id),
  to_email      TEXT NOT NULL,
  kind          TEXT NOT NULL CHECK (kind IN ('magic_link','export_accountant','quote_send','invoice_send')),
  subject       TEXT,
  status        TEXT NOT NULL DEFAULT 'queued' CHECK (status IN ('queued','sent','failed')),
  export_format TEXT CHECK (export_format IN ('pdf','csv') OR export_format IS NULL),
  export_r2_key TEXT,
  related_id    TEXT,
  error         TEXT,
  attempts      INTEGER NOT NULL DEFAULT 0,
  created_at    INTEGER NOT NULL,
  sent_at       INTEGER
);
INSERT INTO email_outbox_new
  (id, user_id, to_email, kind, subject, status, export_format, export_r2_key, related_id, error, attempts, created_at, sent_at)
SELECT
  id, user_id, to_email, kind, subject, status, export_format, export_r2_key, related_id, error, attempts, created_at, sent_at
FROM email_outbox;
DROP TABLE email_outbox;
ALTER TABLE email_outbox_new RENAME TO email_outbox;
CREATE INDEX ix_outbox_status ON email_outbox(status, created_at);
CREATE INDEX ix_outbox_user   ON email_outbox(user_id);
