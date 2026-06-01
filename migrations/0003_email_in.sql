-- F6 Email-in: server-only tables (NEVER added to SYNCABLE_TABLES — they do not sync).

-- One active inbox alias per profile. Opaque random token; rotation overwrites it.
CREATE TABLE profile_inbox_tokens (
  token       TEXT PRIMARY KEY,
  user_id     TEXT NOT NULL REFERENCES users(id),
  profile_id  TEXT NOT NULL REFERENCES profiles(id),
  created_at  INTEGER NOT NULL
);
CREATE UNIQUE INDEX ux_inbox_profile ON profile_inbox_tokens(profile_id);
CREATE INDEX        ix_inbox_user    ON profile_inbox_tokens(user_id);

-- Idempotency + audit for inbound deliveries. message_id is the dedup key.
CREATE TABLE inbound_email_log (
  message_id     TEXT PRIMARY KEY,
  user_id        TEXT,
  profile_id     TEXT,
  transaction_id TEXT,
  status         TEXT NOT NULL CHECK (status IN ('created','failed','rejected','duplicate')),
  reason         TEXT,
  received_at    INTEGER NOT NULL
);
CREATE INDEX ix_inbound_received ON inbound_email_log(received_at);
