-- Additive v2 client workspace schema. IDs are UUIDv7, money is integer cents,
-- and timestamps are epoch milliseconds. Client links are logical references;
-- sync validates their tenancy without preventing tombstones from surviving.
ALTER TABLE clients ADD COLUMN notes TEXT;
ALTER TABLE quotes ADD COLUMN client_id TEXT;
ALTER TABLE invoices ADD COLUMN client_id TEXT;
ALTER TABLE quote_line_items ADD COLUMN unit_label TEXT;
ALTER TABLE invoice_line_items ADD COLUMN unit_label TEXT;

CREATE TABLE catalog_items (
  id                    TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL REFERENCES users(id),
  profile_id            TEXT NOT NULL REFERENCES profiles(id),
  description           TEXT NOT NULL,
  unit_label            TEXT,
  unit_price_cents      INTEGER NOT NULL,
  currency              TEXT NOT NULL DEFAULT 'AUD',
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  deleted_at            INTEGER,
  rev                   INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id TEXT
);
CREATE INDEX ix_catalog_item_user_updated ON catalog_items(user_id, updated_at);

CREATE TABLE client_follow_ups (
  id                    TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL REFERENCES users(id),
  profile_id            TEXT NOT NULL REFERENCES profiles(id),
  client_id             TEXT NOT NULL,
  title                 TEXT NOT NULL,
  due_at                INTEGER NOT NULL,
  timezone              TEXT NOT NULL,
  completed_at          INTEGER,
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  deleted_at            INTEGER,
  rev                   INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id TEXT
);
CREATE INDEX ix_client_follow_up_user_updated ON client_follow_ups(user_id, updated_at);
CREATE INDEX ix_client_follow_up_due ON client_follow_ups(user_id, profile_id, completed_at, deleted_at, due_at);
CREATE INDEX ix_quote_client_history ON quotes(user_id, profile_id, client_id, deleted_at, created_at);
CREATE INDEX ix_invoice_client_history ON invoices(user_id, profile_id, client_id, deleted_at, created_at);
