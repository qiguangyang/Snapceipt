-- migrations/0001_init.sql
-- Snapceipt initial D1 schema (forward-only).
-- ids = UUIDv7 TEXT. Money = INTEGER cents. Timestamps = INTEGER epoch ms. Dates = TEXT 'YYYY-MM-DD'.
-- Syncable tables carry: id, user_id, created_at, updated_at, deleted_at, rev, last_edited_device_id.
PRAGMA foreign_keys = OFF;

-- =========================================================================
-- 1. Identity & Auth
-- =========================================================================
-- users carries user_id (= id, its own tenant key) so the per-tenant sync
-- helpers + delta pull can treat users uniformly with every other syncable
-- table. It's mirrored from id by a trigger rather than a generated column
-- because a STORED/VIRTUAL generated column referencing the PK is parsed
-- inconsistently across SQLite builds.
CREATE TABLE users (
  id                    TEXT PRIMARY KEY,
  user_id               TEXT,
  email                 TEXT,
  email_verified        INTEGER NOT NULL DEFAULT 0,
  display_name          TEXT,
  plan                  TEXT NOT NULL DEFAULT 'free' CHECK (plan IN ('free','pro')),
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  deleted_at            INTEGER,
  rev                   INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id TEXT
);
CREATE TRIGGER trg_users_user_id
  AFTER INSERT ON users
  WHEN NEW.user_id IS NULL
BEGIN
  UPDATE users SET user_id = NEW.id WHERE id = NEW.id;
END;
CREATE UNIQUE INDEX ux_users_email ON users(email) WHERE email IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX ix_users_user_updated ON users(user_id, updated_at);

CREATE TABLE auth_identities (
  id          TEXT PRIMARY KEY,
  user_id     TEXT NOT NULL REFERENCES users(id),
  provider    TEXT NOT NULL CHECK (provider IN ('apple','email')),
  subject     TEXT NOT NULL,
  created_at  INTEGER NOT NULL
);
CREATE UNIQUE INDEX ux_authid_provider_subject ON auth_identities(provider, subject);
CREATE INDEX ix_authid_user ON auth_identities(user_id);

CREATE TABLE email_tokens (
  id          TEXT PRIMARY KEY,
  email       TEXT NOT NULL,
  token_hash  TEXT NOT NULL,
  purpose     TEXT NOT NULL DEFAULT 'magic_link' CHECK (purpose IN ('magic_link')),
  expires_at  INTEGER NOT NULL,
  consumed_at INTEGER,
  created_at  INTEGER NOT NULL
);
CREATE INDEX ix_emailtok_email ON email_tokens(email);
CREATE UNIQUE INDEX ux_emailtok_hash ON email_tokens(token_hash);

-- sessions: column name is `family` (NOT family_id) per Canonical Contracts.
CREATE TABLE sessions (
  id            TEXT PRIMARY KEY,
  user_id       TEXT NOT NULL REFERENCES users(id),
  device_id     TEXT NOT NULL,
  family        TEXT NOT NULL,
  refresh_hash  TEXT NOT NULL,
  created_at    INTEGER NOT NULL,
  last_seen_at  INTEGER,
  expires_at    INTEGER NOT NULL,
  revoked_at    INTEGER
);
CREATE UNIQUE INDEX ux_sessions_refresh ON sessions(refresh_hash);
CREATE INDEX ix_sessions_family ON sessions(family);
CREATE INDEX ix_sessions_user ON sessions(user_id);

CREATE TABLE devices (
  id                    TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL REFERENCES users(id),
  platform              TEXT NOT NULL DEFAULT 'ios' CHECK (platform IN ('ios')),
  model                 TEXT,
  os_version            TEXT,
  apns_token            TEXT,
  push_enabled          INTEGER NOT NULL DEFAULT 1,
  last_sync_cursor      INTEGER,
  last_seen_at          INTEGER,
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  deleted_at            INTEGER,
  rev                   INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id TEXT
);
CREATE INDEX ix_devices_user ON devices(user_id);
CREATE INDEX ix_devices_user_updated ON devices(user_id, updated_at);
CREATE UNIQUE INDEX ux_devices_apns ON devices(apns_token) WHERE apns_token IS NOT NULL;

-- =========================================================================
-- 2. Profiles & Categorization
-- =========================================================================
CREATE TABLE profiles (
  id                    TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL REFERENCES users(id),
  name                  TEXT NOT NULL,
  type                  TEXT NOT NULL CHECK (type IN ('personal','business')),
  initials              TEXT,
  accent_1              TEXT NOT NULL,
  accent_2              TEXT NOT NULL,
  accent_3              TEXT NOT NULL,
  abn                   TEXT,
  gst_registered        INTEGER NOT NULL DEFAULT 0,
  sort_order            INTEGER NOT NULL DEFAULT 0,
  is_default            INTEGER NOT NULL DEFAULT 0,
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  deleted_at            INTEGER,
  rev                   INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id TEXT
);
CREATE INDEX ix_profiles_user ON profiles(user_id);
CREATE INDEX ix_profiles_user_updated ON profiles(user_id, updated_at);

CREATE TABLE categories (
  id                     TEXT PRIMARY KEY,
  user_id                TEXT NOT NULL REFERENCES users(id),
  profile_id             TEXT REFERENCES profiles(id),
  key                    TEXT NOT NULL CHECK (key IN ('meals','groceries','fuel','software','office','home','health','travel','income','custom')),
  label                  TEXT NOT NULL,
  icon                   TEXT NOT NULL,
  tint                   TEXT NOT NULL,
  soft                   TEXT NOT NULL,
  default_deductible_pct INTEGER CHECK (default_deductible_pct BETWEEN 0 AND 100),
  is_income              INTEGER NOT NULL DEFAULT 0,
  sort_order             INTEGER NOT NULL DEFAULT 0,
  created_at             INTEGER NOT NULL,
  updated_at             INTEGER NOT NULL,
  deleted_at             INTEGER,
  rev                    INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id  TEXT
);
CREATE INDEX ix_categories_user ON categories(user_id);
CREATE INDEX ix_categories_user_updated ON categories(user_id, updated_at);

CREATE TABLE smart_rules (
  id                    TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL REFERENCES users(id),
  profile_id            TEXT REFERENCES profiles(id),
  match_type            TEXT NOT NULL DEFAULT 'merchant_contains' CHECK (match_type IN ('merchant_contains','merchant_equals','merchant_regex')),
  matcher               TEXT NOT NULL,
  category_id           TEXT REFERENCES categories(id),
  set_deductible_pct    INTEGER CHECK (set_deductible_pct BETWEEN 0 AND 100),
  set_mode              TEXT CHECK (set_mode IN ('business','personal')),
  priority              INTEGER NOT NULL DEFAULT 0,
  enabled               INTEGER NOT NULL DEFAULT 1,
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  deleted_at            INTEGER,
  rev                   INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id TEXT
);
CREATE INDEX ix_rules_user ON smart_rules(user_id);
CREATE INDEX ix_rules_user_updated ON smart_rules(user_id, updated_at);
CREATE INDEX ix_rules_match ON smart_rules(user_id, profile_id, enabled, priority) WHERE deleted_at IS NULL;

-- =========================================================================
-- 3. Transactions & Line Items
-- =========================================================================
CREATE TABLE transactions (
  id                    TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL REFERENCES users(id),
  profile_id            TEXT NOT NULL REFERENCES profiles(id),
  merchant              TEXT NOT NULL DEFAULT '',
  category_id           TEXT REFERENCES categories(id),
  cat_key               TEXT NOT NULL CHECK (cat_key IN ('meals','groceries','fuel','software','office','home','health','travel','income','custom')),
  amount_cents          INTEGER NOT NULL,
  currency              TEXT NOT NULL DEFAULT 'AUD',
  txn_date              TEXT NOT NULL,
  month_key             TEXT GENERATED ALWAYS AS (substr(txn_date,1,7)) STORED,
  mode                  TEXT NOT NULL DEFAULT 'personal' CHECK (mode IN ('business','personal')),
  tax_label             TEXT,
  deductible_pct        INTEGER CHECK (deductible_pct BETWEEN 0 AND 100),
  payment_method        TEXT,
  is_ai                 INTEGER NOT NULL DEFAULT 0,
  note                  TEXT,
  gst_cents             INTEGER,
  logbook_link          TEXT CHECK (logbook_link IN ('vehicle','wfh') OR logbook_link IS NULL),
  mileage_trip_id       TEXT REFERENCES mileage_trips(id),
  source                TEXT NOT NULL DEFAULT 'manual' CHECK (source IN ('manual','scan','email_in','import')),
  extraction_status     TEXT CHECK (extraction_status IN ('pending','done','failed') OR extraction_status IS NULL),
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  deleted_at            INTEGER,
  rev                   INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id TEXT
);
CREATE INDEX ix_txn_user_updated  ON transactions(user_id, updated_at);
CREATE INDEX ix_txn_profile_date  ON transactions(profile_id, txn_date)  WHERE deleted_at IS NULL;
CREATE INDEX ix_txn_profile_month ON transactions(profile_id, month_key) WHERE deleted_at IS NULL;
CREATE INDEX ix_txn_category      ON transactions(category_id);
CREATE INDEX ix_txn_user_profile  ON transactions(user_id, profile_id, txn_date);

CREATE TABLE line_items (
  id                    TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL REFERENCES users(id),
  transaction_id        TEXT NOT NULL REFERENCES transactions(id),
  name                  TEXT NOT NULL,
  price_cents           INTEGER NOT NULL,
  quantity              INTEGER NOT NULL DEFAULT 1,
  sort_order            INTEGER NOT NULL DEFAULT 0,
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  deleted_at            INTEGER,
  rev                   INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id TEXT
);
CREATE INDEX ix_lineitem_txn          ON line_items(transaction_id);
CREATE INDEX ix_lineitem_user_updated ON line_items(user_id, updated_at);

-- =========================================================================
-- 4. Receipt Images (R2 keys only — binary never in D1)
-- =========================================================================
CREATE TABLE receipt_images (
  id                    TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL REFERENCES users(id),
  profile_id            TEXT REFERENCES profiles(id),
  transaction_id        TEXT REFERENCES transactions(id),
  r2_key                TEXT NOT NULL,
  thumb_r2_key          TEXT,
  content_type          TEXT NOT NULL DEFAULT 'image/jpeg',
  byte_size             INTEGER,
  width                 INTEGER,
  height                INTEGER,
  page_index            INTEGER NOT NULL DEFAULT 0,
  ocr_text              TEXT,
  ocr_source            TEXT CHECK (ocr_source IN ('vision_on_device','workers_ai') OR ocr_source IS NULL),
  extraction_json       TEXT,
  extraction_model      TEXT,
  source                TEXT NOT NULL DEFAULT 'scan' CHECK (source IN ('scan','email_in')),
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  deleted_at            INTEGER,
  rev                   INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id TEXT
);
CREATE INDEX ix_img_txn          ON receipt_images(transaction_id);
CREATE INDEX ix_img_user_updated ON receipt_images(user_id, updated_at);
CREATE UNIQUE INDEX ux_img_r2key ON receipt_images(r2_key);

-- =========================================================================
-- 5. Budgets & Loyalty
-- =========================================================================
CREATE TABLE budgets (
  id                    TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL REFERENCES users(id),
  profile_id            TEXT NOT NULL REFERENCES profiles(id),
  category_id           TEXT REFERENCES categories(id),
  cat_key               TEXT,
  label                 TEXT NOT NULL,
  period                TEXT NOT NULL DEFAULT 'monthly' CHECK (period IN ('monthly')),
  month_key             TEXT,
  cap_cents             INTEGER NOT NULL,
  currency              TEXT NOT NULL DEFAULT 'AUD',
  alert_threshold_pct   INTEGER NOT NULL DEFAULT 90 CHECK (alert_threshold_pct BETWEEN 1 AND 200),
  alert_sent_at         INTEGER,
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  deleted_at            INTEGER,
  rev                   INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id TEXT
);
CREATE INDEX ix_budget_user_updated ON budgets(user_id, updated_at);
CREATE INDEX ix_budget_profile      ON budgets(profile_id, month_key) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX ux_budget_scope ON budgets(profile_id, category_id, month_key) WHERE deleted_at IS NULL;

CREATE TABLE loyalty_cards (
  id                    TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL REFERENCES users(id),
  profile_id            TEXT REFERENCES profiles(id),
  brand                 TEXT NOT NULL,
  sub_brand             TEXT,
  number                TEXT NOT NULL,
  barcode_format        TEXT CHECK (barcode_format IN ('code128','ean13','qr','aztec','pdf417') OR barcode_format IS NULL),
  points_label          TEXT,
  color_1               TEXT NOT NULL,
  color_2               TEXT NOT NULL,
  sort_order            INTEGER NOT NULL DEFAULT 0,
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  deleted_at            INTEGER,
  rev                   INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id TEXT
);
CREATE INDEX ix_loyalty_user_updated ON loyalty_cards(user_id, updated_at);
CREATE INDEX ix_loyalty_user         ON loyalty_cards(user_id) WHERE deleted_at IS NULL;

-- =========================================================================
-- 6. Logbooks: Mileage & WFH
-- =========================================================================
CREATE TABLE mileage_trips (
  id                    TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL REFERENCES users(id),
  profile_id            TEXT NOT NULL REFERENCES profiles(id),
  trip_date             TEXT NOT NULL,
  from_label            TEXT,
  to_label              TEXT,
  purpose               TEXT,
  distance_m            INTEGER NOT NULL,
  is_business           INTEGER NOT NULL DEFAULT 1,
  rate_cents_per_km     INTEGER,
  claim_cents           INTEGER,
  auto_tracked          INTEGER NOT NULL DEFAULT 0,
  vehicle_id            TEXT REFERENCES vehicles(id),
  odometer_start_m      INTEGER,
  odometer_end_m        INTEGER,
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  deleted_at            INTEGER,
  rev                   INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id TEXT
);
CREATE INDEX ix_trip_user_updated ON mileage_trips(user_id, updated_at);
CREATE INDEX ix_trip_profile_date ON mileage_trips(profile_id, trip_date) WHERE deleted_at IS NULL;

CREATE TABLE wfh_logs (
  id                    TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL REFERENCES users(id),
  profile_id            TEXT NOT NULL REFERENCES profiles(id),
  log_date              TEXT NOT NULL,
  minutes               INTEGER NOT NULL,
  note                  TEXT,
  rate_cents_per_hour   INTEGER,
  claim_cents           INTEGER,
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  deleted_at            INTEGER,
  rev                   INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id TEXT
);
CREATE INDEX ix_wfh_user_updated ON wfh_logs(user_id, updated_at);
CREATE UNIQUE INDEX ux_wfh_profile_date ON wfh_logs(profile_id, log_date) WHERE deleted_at IS NULL;

CREATE TABLE vehicles (
  id                    TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL REFERENCES users(id),
  profile_id            TEXT NOT NULL REFERENCES profiles(id),
  make                  TEXT,
  model                 TEXT,
  engine_cc             INTEGER,
  registration          TEXT,
  logbook_start_date    TEXT,
  logbook_end_date      TEXT,
  business_use_pct      INTEGER,
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  deleted_at            INTEGER,
  rev                   INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id TEXT
);
CREATE INDEX ix_vehicle_user_updated ON vehicles(user_id, updated_at);
CREATE INDEX ix_vehicle_profile      ON vehicles(profile_id) WHERE deleted_at IS NULL;

CREATE TABLE vehicle_years (
  id                    TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL REFERENCES users(id),
  profile_id            TEXT NOT NULL REFERENCES profiles(id),
  vehicle_id            TEXT NOT NULL REFERENCES vehicles(id),
  fy_start_year         INTEGER NOT NULL,
  odometer_open_m       INTEGER,
  odometer_close_m      INTEGER,
  fuel_cents            INTEGER NOT NULL DEFAULT 0,
  rego_cents            INTEGER NOT NULL DEFAULT 0,
  insurance_cents       INTEGER NOT NULL DEFAULT 0,
  servicing_cents       INTEGER NOT NULL DEFAULT 0,
  other_cents           INTEGER NOT NULL DEFAULT 0,
  depreciation_cents    INTEGER NOT NULL DEFAULT 0,
  business_use_pct      INTEGER,
  claim_cents           INTEGER,
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  deleted_at            INTEGER,
  rev                   INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id TEXT
);
CREATE INDEX ix_vehicle_year_user_updated ON vehicle_years(user_id, updated_at);
CREATE UNIQUE INDEX ux_vehicle_year ON vehicle_years(vehicle_id, fy_start_year) WHERE deleted_at IS NULL;

-- =========================================================================
-- 7. Quotes & Quote Line Items
-- =========================================================================
CREATE TABLE quotes (
  id                    TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL REFERENCES users(id),
  profile_id            TEXT NOT NULL REFERENCES profiles(id),
  number                TEXT,
  client_name           TEXT,
  client_email          TEXT,
  gst_enabled           INTEGER NOT NULL DEFAULT 1,
  subtotal_cents        INTEGER NOT NULL DEFAULT 0,
  gst_cents             INTEGER NOT NULL DEFAULT 0,
  total_cents           INTEGER NOT NULL DEFAULT 0,
  currency              TEXT NOT NULL DEFAULT 'AUD',
  status                TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','sent','accepted','declined','expired','invoiced')),
  valid_until           TEXT,
  sent_at               INTEGER,
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  deleted_at            INTEGER,
  rev                   INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id TEXT
);
CREATE INDEX ix_quote_user_updated   ON quotes(user_id, updated_at);
CREATE INDEX ix_quote_profile_status ON quotes(profile_id, status) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX ux_quote_number  ON quotes(user_id, number) WHERE number IS NOT NULL AND deleted_at IS NULL;

CREATE TABLE quote_line_items (
  id                    TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL REFERENCES users(id),
  quote_id              TEXT NOT NULL REFERENCES quotes(id),
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
CREATE INDEX ix_qli_quote        ON quote_line_items(quote_id);
CREATE INDEX ix_qli_user_updated ON quote_line_items(user_id, updated_at);

-- =========================================================================
-- 8. Operational: Email Outbox & Tax Settings
-- =========================================================================
CREATE TABLE email_outbox (
  id            TEXT PRIMARY KEY,
  user_id       TEXT REFERENCES users(id),
  to_email      TEXT NOT NULL,
  kind          TEXT NOT NULL CHECK (kind IN ('magic_link','export_accountant','quote_send')),
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
CREATE INDEX ix_outbox_status ON email_outbox(status, created_at);
CREATE INDEX ix_outbox_user   ON email_outbox(user_id);

CREATE TABLE tax_settings (
  id                          TEXT PRIMARY KEY,
  user_id                     TEXT NOT NULL REFERENCES users(id),
  profile_id                  TEXT NOT NULL REFERENCES profiles(id),
  gst_rate_bps                INTEGER NOT NULL DEFAULT 1000,
  financial_year_start_month  INTEGER NOT NULL DEFAULT 7,
  meals_deductible_pct        INTEGER NOT NULL DEFAULT 50,
  wfh_rate_cents_per_hour     INTEGER NOT NULL DEFAULT 70,
  mileage_rate_cents_per_km   INTEGER NOT NULL DEFAULT 88,
  accountant_email            TEXT,
  created_at                  INTEGER NOT NULL,
  updated_at                  INTEGER NOT NULL,
  deleted_at                  INTEGER,
  rev                         INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id       TEXT
);
CREATE UNIQUE INDEX ux_tax_profile  ON tax_settings(profile_id) WHERE deleted_at IS NULL;
CREATE INDEX ix_tax_user_updated    ON tax_settings(user_id, updated_at);

-- =========================================================================
-- 9. Sync support: server-side idempotency log (mutation_queue mirror).
--    Not synced to device; bounded retention (GC of rows older than ~30d).
--    Canonical Contracts pin the columns (mutation_id, user_id, result_json,
--    created_at); the remaining columns capture the mutation's provenance/
--    outcome for replay + audit.
-- =========================================================================
CREATE TABLE processed_mutations (
  mutation_id  TEXT PRIMARY KEY,
  user_id      TEXT NOT NULL,
  device_id    TEXT NOT NULL,
  entity_type  TEXT NOT NULL,
  entity_id    TEXT NOT NULL,
  op           TEXT NOT NULL CHECK (op IN ('upsert','delete')),
  status       TEXT NOT NULL CHECK (status IN ('applied','conflict','duplicate','rejected')),
  result_json  TEXT NOT NULL,
  created_at   INTEGER NOT NULL
);
CREATE INDEX ix_procmut_user ON processed_mutations(user_id, created_at);
