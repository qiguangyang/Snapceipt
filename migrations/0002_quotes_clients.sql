-- migrations/0002_quotes_clients.sql
-- F5 Quotes: the saved-clients address book (synced) + the server-only per-user
-- quote-number counter. Forward-only.
-- ids = UUIDv7 TEXT. Money = INTEGER cents. Timestamps = INTEGER epoch ms.
-- Syncable tables carry: id, user_id, created_at, updated_at, deleted_at, rev, last_edited_device_id.
PRAGMA foreign_keys = OFF;

-- =========================================================================
-- clients — the saved-clients address book (synced via the generic /sync).
-- =========================================================================
CREATE TABLE clients (
  id                    TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL REFERENCES users(id),
  profile_id            TEXT,
  name                  TEXT NOT NULL,
  email                 TEXT,
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  deleted_at            INTEGER,
  rev                   INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id TEXT
);
CREATE INDEX ix_client_user_updated ON clients(user_id, updated_at);
CREATE INDEX ix_client_profile      ON clients(profile_id) WHERE deleted_at IS NULL;

-- =========================================================================
-- quote_counters — server-only per-user SN-#### sequence. NOT synced. The send
-- route increments next_seq atomically (INSERT … ON CONFLICT … RETURNING) so
-- concurrent sends never collide; quotes.ux_quote_number is the unique backstop.
-- =========================================================================
CREATE TABLE quote_counters (
  user_id  TEXT PRIMARY KEY REFERENCES users(id),
  next_seq INTEGER NOT NULL
);
