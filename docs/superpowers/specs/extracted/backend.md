# Snapceipt — Cloudflare D1 (SQLite) Schema for a Local-First AUD Expense Tracker

## 0. Conventions & D1/SQLite Specifics (read first)
Verified against Cloudflare D1 docs (see Sources at end). These conventions apply to every table below.

Storage classes — SQLite has only NULL, INTEGER, REAL, TEXT, BLOB. D1 inherits this. So:
- IDs: TEXT holding a UUIDv7 (lexicographically sortable, good for cursors/indexes). We do NOT use INTEGER AUTOINCREMENT PKs because rows are created offline on-device and must merge without server round-trips. UUIDv7 is client-generatable, collision-free, and sortable.
- Money: INTEGER minor units (cents) + a separate TEXT ISO-4217 code. NEVER REAL/float for money. amount_cents INTEGER, currency TEXT DEFAULT 'AUD'. AUD has exponent 2, so 1 unit = 100 cents. Signed: negative = expense, positive = income (matches prototype's signed `amount`).
- Timestamps: INTEGER epoch milliseconds (UTC). Millisecond resolution matters for last-write-wins (LWW) tie-breaking. Calendar dates with no time-of-day (purchase date, budget month, trip date, WFH date) are stored as TEXT 'YYYY-MM-DD' (matches the prototype's ISO date strings) so date-only comparisons stay correct across timezones.
- Booleans: INTEGER 0/1 (SQLite has no BOOLEAN).
- Enums: TEXT with a CHECK(... IN (...)) constraint. Keeps it self-documenting and validated server-side.
- JSON: TEXT, queried with D1's JSON functions when needed. Used only for genuinely variable-shape payloads (mutation queue ops, accent palette is modeled as 3 explicit columns instead — see profiles).

Keys & indexes:
- INTEGER PRIMARY KEY is auto-indexed by SQLite; a TEXT PRIMARY KEY is also backed by an implicit unique index, so PK lookups are fine. We add explicit indexes on every FK column and every delta-sync predicate (user_id, profile_id, updated_at).
- Foreign keys: D1 supports FK constraints in DDL. Because cross-statement FK enforcement during batched imports can be awkward and D1 batches statements, we DECLARE foreign keys for documentation/integrity intent but the worker should wrap multi-table writes in a transaction and may toggle `PRAGMA foreign_keys` per the sync import path. App-level integrity (always scope by user_id) is the real guard.
- Partial indexes (CREATE INDEX ... WHERE) are supported — we use them to keep tombstoned rows out of hot read paths and to index only-active rows.
- Generated columns (STORED/VIRTUAL) supported and indexable — used for the month bucket on transactions and the deductible_cents rollup.
- After migrations, run `PRAGMA optimize;` (runs ANALYZE) so the planner uses the new indexes.

Limits that shaped the design: 100 columns/table (we are well under), 2 MB max row (so receipt image BYTES never live in a row — only R2 object keys + small thumbnails are referenced; binary stays in R2), 100 bound params/query (sync pull pages in chunks), 10 GB DB on Workers Paid (per-user data is tiny; fine for the foreseeable scale).

Multi-profile scoping: D1 is multi-tenant (all users in one DB). Every domain row carries BOTH user_id (the tenant/owner — the security boundary) and, where applicable, profile_id (the sub-scope a user switches between in the UI). The worker ALWAYS filters WHERE user_id = :authedUser on every query — never trust a client-supplied profile_id alone.

## 1. Identity & Auth (users, auth_identities, email_tokens, devices)
Sign in with Apple + email magic-link. Apple gives a stable subject; magic-link is email-based. One user can have multiple identities (Apple + email) — modeled in a separate auth_identities table so a person isn't duplicated.

users
- id TEXT PRIMARY KEY                         -- UUIDv7
- email TEXT NULL                             -- canonical email (may arrive via Apple relay or magic-link)
- email_verified INTEGER NOT NULL DEFAULT 0
- display_name TEXT NULL                       -- e.g. 'Maya Reyes' (from prototype identity block)
- plan TEXT NOT NULL DEFAULT 'free' CHECK (plan IN ('free','pro'))   -- 'Pro' badge in profile screen
- created_at INTEGER NOT NULL                  -- epoch ms
- updated_at INTEGER NOT NULL
- deleted_at INTEGER NULL                      -- tombstone (account closure)
UNIQUE INDEX ux_users_email ON users(email) WHERE email IS NOT NULL AND deleted_at IS NULL

auth_identities  (provider links → users)
- id TEXT PRIMARY KEY
- user_id TEXT NOT NULL REFERENCES users(id)
- provider TEXT NOT NULL CHECK (provider IN ('apple','email'))
- subject TEXT NOT NULL                        -- Apple `sub`, or normalized email for magic-link
- created_at INTEGER NOT NULL
UNIQUE INDEX ux_authid_provider_subject ON auth_identities(provider, subject)
INDEX ix_authid_user ON auth_identities(user_id)

email_tokens  (magic-link sign-in; short-lived, single-use)
- id TEXT PRIMARY KEY
- email TEXT NOT NULL
- token_hash TEXT NOT NULL                     -- store a hash, never the raw token
- purpose TEXT NOT NULL DEFAULT 'magic_link' CHECK (purpose IN ('magic_link'))
- expires_at INTEGER NOT NULL                  -- epoch ms
- consumed_at INTEGER NULL
- created_at INTEGER NOT NULL
INDEX ix_emailtok_email ON email_tokens(email)
UNIQUE INDEX ux_emailtok_hash ON email_tokens(token_hash)
  (No sync columns — server-only operational table, never pulled to device.)

devices  (per-install; powers push budget alerts + per-device sync cursor)
- id TEXT PRIMARY KEY                          -- client-generated install UUID
- user_id TEXT NOT NULL REFERENCES users(id)
- platform TEXT NOT NULL DEFAULT 'ios' CHECK (platform IN ('ios'))
- model TEXT NULL
- os_version TEXT NULL
- apns_token TEXT NULL                         -- for budget push alerts
- push_enabled INTEGER NOT NULL DEFAULT 1
- last_sync_cursor INTEGER NULL                -- high-water mark (max updated_at this device has pulled)
- last_seen_at INTEGER NULL
- created_at INTEGER NOT NULL
- updated_at INTEGER NOT NULL
- deleted_at INTEGER NULL
INDEX ix_devices_user ON devices(user_id)
UNIQUE INDEX ux_devices_apns ON devices(apns_token) WHERE apns_token IS NOT NULL
  (The sync cursor lives per-device so multiple devices on one account each track their own delta position.)

## 2. Profiles & Categorization (profiles, categories, smart_rules)
A profile is the user's switchable persona (Personal / Business). The prototype stores name, type, initials, a 3-colour accent palette, ABN, gstRegistered. Accent palette is 3 fixed slots → 3 explicit columns (faster than JSON, no parsing, indexable if ever needed). Categories are the 9 fixed seeds but made per-user editable; smart_rules drive AI/auto categorisation.

profiles
- id TEXT PRIMARY KEY
- user_id TEXT NOT NULL REFERENCES users(id)
- name TEXT NOT NULL                           -- 'Studio North'
- type TEXT NOT NULL CHECK (type IN ('personal','business'))
- initials TEXT NULL                           -- 'MR'; derivable but cached (prototype's apInitials)
- accent_1 TEXT NOT NULL                       -- palette[0] tint  e.g. '#0E7C72'
- accent_2 TEXT NOT NULL                       -- palette[1] soft  e.g. '#DCF0ED'
- accent_3 TEXT NOT NULL                       -- palette[2] deep  e.g. '#0A5950'
- abn TEXT NULL                                -- business only
- gst_registered INTEGER NOT NULL DEFAULT 0
- sort_order INTEGER NOT NULL DEFAULT 0        -- profile switcher ordering
- is_default INTEGER NOT NULL DEFAULT 0        -- which profile opens on launch
- created_at INTEGER NOT NULL
- updated_at INTEGER NOT NULL
- deleted_at INTEGER NULL
INDEX ix_profiles_user ON profiles(user_id)
INDEX ix_profiles_user_updated ON profiles(user_id, updated_at)   -- delta sync

categories  (the 9 seeds, but per-user so they can rename/add)
- id TEXT PRIMARY KEY
- user_id TEXT NOT NULL REFERENCES users(id)
- profile_id TEXT NULL REFERENCES profiles(id)  -- NULL = shared across all the user's profiles
- key TEXT NOT NULL CHECK (key IN ('meals','groceries','fuel','software','office','home','health','travel','income','custom'))
- label TEXT NOT NULL                           -- 'Meals & Coffee'
- icon TEXT NOT NULL                            -- icon name e.g. 'cup' (matches CATS)
- tint TEXT NOT NULL                            -- '#E8602C'
- soft TEXT NOT NULL                            -- '#FBEADF'
- default_deductible_pct INTEGER NULL CHECK (default_deductible_pct BETWEEN 0 AND 100)
- is_income INTEGER NOT NULL DEFAULT 0          -- the 'income' category
- sort_order INTEGER NOT NULL DEFAULT 0
- created_at INTEGER NOT NULL
- updated_at INTEGER NOT NULL
- deleted_at INTEGER NULL
INDEX ix_categories_user ON categories(user_id)
INDEX ix_categories_user_updated ON categories(user_id, updated_at)

smart_rules  (matcher → category / deductible; backs 'AI auto-categorise' + the `ai` flag)
- id TEXT PRIMARY KEY
- user_id TEXT NOT NULL REFERENCES users(id)
- profile_id TEXT NULL REFERENCES profiles(id)  -- NULL = applies to all profiles
- match_type TEXT NOT NULL DEFAULT 'merchant_contains' CHECK (match_type IN ('merchant_contains','merchant_equals','merchant_regex'))
- matcher TEXT NOT NULL                          -- e.g. 'adobe', 'bp service'
- category_id TEXT NULL REFERENCES categories(id)
- set_deductible_pct INTEGER NULL CHECK (set_deductible_pct BETWEEN 0 AND 100)
- set_mode TEXT NULL CHECK (set_mode IN ('business','personal'))
- priority INTEGER NOT NULL DEFAULT 0            -- higher wins on ties
- enabled INTEGER NOT NULL DEFAULT 1
- created_at INTEGER NOT NULL
- updated_at INTEGER NOT NULL
- deleted_at INTEGER NULL
INDEX ix_rules_user ON smart_rules(user_id)
INDEX ix_rules_user_updated ON smart_rules(user_id, updated_at)
INDEX ix_rules_match ON smart_rules(user_id, profile_id, enabled, priority) WHERE deleted_at IS NULL

## 3. Transactions & Line Items (transactions, line_items)
The core table. Maps the prototype seed exactly: id, merchant, category, signed amount, date, mode, tax label, deductible %, payment method, ai flag, note, gst amount, logbook link. Money in cents; the GST amount stored as cents; deductible as 0–100 int. `cat` is kept BOTH as a stable enum key (cat_key) and an FK (category_id) so categorisation survives even if a custom category row is edited.

transactions
- id TEXT PRIMARY KEY                            -- UUIDv7, client-generated
- user_id TEXT NOT NULL REFERENCES users(id)
- profile_id TEXT NOT NULL REFERENCES profiles(id)
- merchant TEXT NOT NULL DEFAULT ''
- category_id TEXT NULL REFERENCES categories(id)
- cat_key TEXT NOT NULL CHECK (cat_key IN ('meals','groceries','fuel','software','office','home','health','travel','income','custom'))
- amount_cents INTEGER NOT NULL                  -- signed: negative=expense, positive=income
- currency TEXT NOT NULL DEFAULT 'AUD'           -- ISO-4217
- txn_date TEXT NOT NULL                         -- 'YYYY-MM-DD' (date-only, matches seed)
- month_key TEXT GENERATED ALWAYS AS (substr(txn_date,1,7)) STORED   -- 'YYYY-MM' for month filters/rollups
- mode TEXT NOT NULL DEFAULT 'personal' CHECK (mode IN ('business','personal'))
- tax_label TEXT NULL                            -- prototype `tax`: 'Client meeting','Invoice #1042'
- deductible_pct INTEGER NULL CHECK (deductible_pct BETWEEN 0 AND 100)
- payment_method TEXT NULL                       -- 'Amex Business','Visa •2241','Apple Pay'
- is_ai INTEGER NOT NULL DEFAULT 0               -- `ai` flag (auto-sorted)
- note TEXT NULL
- gst_cents INTEGER NULL                         -- GST included, in cents (0 allowed; NULL = unknown)
- logbook_link TEXT NULL CHECK (logbook_link IN ('vehicle','wfh') OR logbook_link IS NULL)
- mileage_trip_id TEXT NULL REFERENCES mileage_trips(id)   -- concrete link when logbook_link='vehicle'
- source TEXT NOT NULL DEFAULT 'manual' CHECK (source IN ('manual','scan','email_in','import'))
- extraction_status TEXT NULL CHECK (extraction_status IN ('pending','done','failed') OR extraction_status IS NULL)
- created_at INTEGER NOT NULL
- updated_at INTEGER NOT NULL
- deleted_at INTEGER NULL
INDEX ix_txn_user_updated ON transactions(user_id, updated_at)                 -- PRIMARY delta-sync index
INDEX ix_txn_profile_date ON transactions(profile_id, txn_date) WHERE deleted_at IS NULL  -- list/Activity screen
INDEX ix_txn_profile_month ON transactions(profile_id, month_key) WHERE deleted_at IS NULL -- SummaryCard / budgets
INDEX ix_txn_category ON transactions(category_id)
INDEX ix_txn_user_profile ON transactions(user_id, profile_id, txn_date)
  Note: deductible_cents for reports can be computed at query time (amount_cents * deductible_pct / 100) or added later as a VIRTUAL generated column; left as a query to avoid sign/NULL edge cases.

line_items  (prototype {name, price}; also reused for parsed receipt lines)
- id TEXT PRIMARY KEY
- user_id TEXT NOT NULL REFERENCES users(id)        -- denormalized for tenant-scoped sync
- transaction_id TEXT NOT NULL REFERENCES transactions(id)
- name TEXT NOT NULL
- price_cents INTEGER NOT NULL
- quantity INTEGER NOT NULL DEFAULT 1
- sort_order INTEGER NOT NULL DEFAULT 0
- created_at INTEGER NOT NULL
- updated_at INTEGER NOT NULL
- deleted_at INTEGER NULL
INDEX ix_lineitem_txn ON line_items(transaction_id)
INDEX ix_lineitem_user_updated ON line_items(user_id, updated_at)            -- delta sync
  (Soft-delete here too so deletes propagate; cascade is emulated in the worker by tombstoning children when a parent is tombstoned, since LWW sync must SEE the deletion, not have it silently cascade.)

## 4. Receipt Images (receipt_images) — R2 keys only
Binary never lives in D1 (2 MB row cap + cost). VisionKit/email-in produce images that go to R2; D1 stores object keys, a thumbnail key, and the OCR text + extraction metadata. One transaction can have multiple images (multi-page scans); an image can also exist before a transaction is created (capture-first flow).

receipt_images
- id TEXT PRIMARY KEY
- user_id TEXT NOT NULL REFERENCES users(id)
- profile_id TEXT NULL REFERENCES profiles(id)
- transaction_id TEXT NULL REFERENCES transactions(id)   -- NULL until linked
- r2_key TEXT NOT NULL                          -- full-res object key in R2
- thumb_r2_key TEXT NULL                        -- small thumbnail object key
- content_type TEXT NOT NULL DEFAULT 'image/jpeg'
- byte_size INTEGER NULL
- width INTEGER NULL
- height INTEGER NULL
- page_index INTEGER NOT NULL DEFAULT 0         -- multi-page scans
- ocr_text TEXT NULL                            -- on-device OCR dump OR Workers AI OCR (email-in)
- ocr_source TEXT NULL CHECK (ocr_source IN ('vision_on_device','workers_ai') OR ocr_source IS NULL)
- extraction_json TEXT NULL                     -- DeepSeek JSON result (audit / re-parse)
- extraction_model TEXT NULL                    -- 'deepseek-v4-flash'
- source TEXT NOT NULL DEFAULT 'scan' CHECK (source IN ('scan','email_in'))
- created_at INTEGER NOT NULL
- updated_at INTEGER NOT NULL
- deleted_at INTEGER NULL
INDEX ix_img_txn ON receipt_images(transaction_id)
INDEX ix_img_user_updated ON receipt_images(user_id, updated_at)
UNIQUE INDEX ux_img_r2key ON receipt_images(r2_key)
  Lifecycle: deleting a transaction tombstones its images; a background worker reclaims the R2 objects after the tombstone has been confirmed synced to all the user's devices (so an offline device can still show the receipt until it catches up).

## 5. Budgets & Loyalty (budgets, loyalty_cards)
Both built REAL in v1. Budgets are per category / profile / month and feed the Home BudgetRow + push alerts. Loyalty cards store brand, number, points, colour, and barcode metadata for on-device rendering.

budgets
- id TEXT PRIMARY KEY
- user_id TEXT NOT NULL REFERENCES users(id)
- profile_id TEXT NOT NULL REFERENCES profiles(id)
- category_id TEXT NULL REFERENCES categories(id)     -- NULL = whole-profile budget
- cat_key TEXT NULL                                    -- denormalized label e.g. 'groceries'
- label TEXT NOT NULL                                  -- 'Groceries','Eating out','Vehicle & travel'
- period TEXT NOT NULL DEFAULT 'monthly' CHECK (period IN ('monthly'))
- month_key TEXT NULL                                  -- 'YYYY-MM'; NULL = recurring every month
- cap_cents INTEGER NOT NULL                           -- the budget limit (prototype `cap`)
- currency TEXT NOT NULL DEFAULT 'AUD'
- alert_threshold_pct INTEGER NOT NULL DEFAULT 90 CHECK (alert_threshold_pct BETWEEN 1 AND 200) -- push at 90%/over
- alert_sent_at INTEGER NULL                           -- dedupe push per period
- created_at INTEGER NOT NULL
- updated_at INTEGER NOT NULL
- deleted_at INTEGER NULL
INDEX ix_budget_user_updated ON budgets(user_id, updated_at)
INDEX ix_budget_profile ON budgets(profile_id, month_key) WHERE deleted_at IS NULL
UNIQUE INDEX ux_budget_scope ON budgets(profile_id, category_id, month_key) WHERE deleted_at IS NULL
  (`spent` is NOT stored — it's computed by summing matching transactions for the period; storing it would double-write and drift. The push-alert worker recomputes spent vs cap and fires APNs when crossing the threshold, then sets alert_sent_at.)

loyalty_cards
- id TEXT PRIMARY KEY
- user_id TEXT NOT NULL REFERENCES users(id)
- profile_id TEXT NULL REFERENCES profiles(id)         -- usually personal; NULL = available to all
- brand TEXT NOT NULL                                  -- 'Everyday Rewards'
- sub_brand TEXT NULL                                  -- 'Woolworths'
- number TEXT NOT NULL                                 -- card number string (keep leading spaces/format)
- barcode_format TEXT NULL CHECK (barcode_format IN ('code128','ean13','qr','aztec','pdf417') OR barcode_format IS NULL)
- points_label TEXT NULL                               -- '2,140 pts','$12 rewards' (free-form display)
- color_1 TEXT NOT NULL                                -- gradient start (prototype c1)
- color_2 TEXT NOT NULL                                -- gradient end   (prototype c2)
- sort_order INTEGER NOT NULL DEFAULT 0
- created_at INTEGER NOT NULL
- updated_at INTEGER NOT NULL
- deleted_at INTEGER NULL
INDEX ix_loyalty_user_updated ON loyalty_cards(user_id, updated_at)
INDEX ix_loyalty_user ON loyalty_cards(user_id) WHERE deleted_at IS NULL

## 6. Logbooks: Mileage & WFH (mileage_trips, wfh_logs)
Both modeled REAL for data, even though GPS auto-track UI is a placeholder — manual trip entry and the WFH log are functional, and transactions link to vehicle trips via mileage_trip_id. Distances stored as integer metres (avoids float drift on km), rates as integer cents.

mileage_trips
- id TEXT PRIMARY KEY
- user_id TEXT NOT NULL REFERENCES users(id)
- profile_id TEXT NOT NULL REFERENCES profiles(id)
- trip_date TEXT NOT NULL                              -- 'YYYY-MM-DD'
- from_label TEXT NULL                                 -- 'Studio'
- to_label TEXT NULL                                   -- 'The Grounds (client)'
- purpose TEXT NULL                                    -- 'Client meeting'
- distance_m INTEGER NOT NULL                          -- metres (12.4 km -> 12400)
- is_business INTEGER NOT NULL DEFAULT 1               -- prototype `biz`
- rate_cents_per_km INTEGER NULL                       -- ATO cents-per-km method (e.g. 88c -> 88)
- claim_cents INTEGER NULL                             -- computed claimable (cached for reports)
- auto_tracked INTEGER NOT NULL DEFAULT 0              -- 0 in v1 (GPS auto-track is placeholder)
- created_at INTEGER NOT NULL
- updated_at INTEGER NOT NULL
- deleted_at INTEGER NULL
INDEX ix_trip_user_updated ON mileage_trips(user_id, updated_at)
INDEX ix_trip_profile_date ON mileage_trips(profile_id, trip_date) WHERE deleted_at IS NULL

wfh_logs
- id TEXT PRIMARY KEY
- user_id TEXT NOT NULL REFERENCES users(id)
- profile_id TEXT NOT NULL REFERENCES profiles(id)
- log_date TEXT NOT NULL                               -- 'YYYY-MM-DD'
- minutes INTEGER NOT NULL                             -- store minutes (7.5h -> 450) to stay integer
- note TEXT NULL                                       -- 'Design + admin'
- rate_cents_per_hour INTEGER NULL                     -- ATO fixed rate (67c -> 67)
- claim_cents INTEGER NULL                             -- cached claimable
- created_at INTEGER NOT NULL
- updated_at INTEGER NOT NULL
- deleted_at INTEGER NULL
INDEX ix_wfh_user_updated ON wfh_logs(user_id, updated_at)
UNIQUE INDEX ux_wfh_profile_date ON wfh_logs(profile_id, log_date) WHERE deleted_at IS NULL  -- one entry/day

## 7. Quotes & Quote Line Items (quotes, quote_line_items)
Business quotes: client, line items, GST toggle, total, status. Totals stored in cents and recomputed server-side from line items + gst flag so they can never disagree with the lines.

quotes
- id TEXT PRIMARY KEY
- user_id TEXT NOT NULL REFERENCES users(id)
- profile_id TEXT NOT NULL REFERENCES profiles(id)
- number TEXT NULL                                     -- 'SN-0042' (human reference)
- client_name TEXT NULL                                -- 'Northwind Studio'
- client_email TEXT NULL                               -- 'accounts@northwind.co' (for emailed send)
- gst_enabled INTEGER NOT NULL DEFAULT 1               -- the GST (10%) toggle
- subtotal_cents INTEGER NOT NULL DEFAULT 0
- gst_cents INTEGER NOT NULL DEFAULT 0
- total_cents INTEGER NOT NULL DEFAULT 0
- currency TEXT NOT NULL DEFAULT 'AUD'
- status TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','sent','accepted','declined','expired','invoiced'))
- valid_until TEXT NULL                                -- 'YYYY-MM-DD' (14-day validity)
- sent_at INTEGER NULL
- created_at INTEGER NOT NULL
- updated_at INTEGER NOT NULL
- deleted_at INTEGER NULL
INDEX ix_quote_user_updated ON quotes(user_id, updated_at)
INDEX ix_quote_profile_status ON quotes(profile_id, status) WHERE deleted_at IS NULL
UNIQUE INDEX ux_quote_number ON quotes(user_id, number) WHERE number IS NOT NULL AND deleted_at IS NULL

quote_line_items
- id TEXT PRIMARY KEY
- user_id TEXT NOT NULL REFERENCES users(id)
- quote_id TEXT NOT NULL REFERENCES quotes(id)
- description TEXT NOT NULL                            -- 'Logo & visual system'
- quantity INTEGER NOT NULL DEFAULT 1                  -- prototype `qty`
- unit_price_cents INTEGER NOT NULL                    -- prototype `price`
- line_total_cents INTEGER GENERATED ALWAYS AS (quantity * unit_price_cents) STORED
- sort_order INTEGER NOT NULL DEFAULT 0
- created_at INTEGER NOT NULL
- updated_at INTEGER NOT NULL
- deleted_at INTEGER NULL
INDEX ix_qli_quote ON quote_line_items(quote_id)
INDEX ix_qli_user_updated ON quote_line_items(user_id, updated_at)

## 8. Operational: Email Outbox & Tax Settings (email_outbox, tax_settings)
Supporting tables for the email service (magic-link, send-to-accountant exports, email-in receipts) and AU tax config. Email-in inbound parsing creates receipt_images/transactions directly, so only OUTBOUND/log state is tabled here.

email_outbox  (server-only; magic-link + accountant exports. NOT synced to device.)
- id TEXT PRIMARY KEY
- user_id TEXT NULL REFERENCES users(id)               -- NULL allowed for pre-signup magic-link
- to_email TEXT NOT NULL
- kind TEXT NOT NULL CHECK (kind IN ('magic_link','export_accountant','quote_send'))
- subject TEXT NULL
- status TEXT NOT NULL DEFAULT 'queued' CHECK (status IN ('queued','sent','failed'))
- export_format TEXT NULL CHECK (export_format IN ('pdf','csv') OR export_format IS NULL)
- export_r2_key TEXT NULL                              -- generated PDF/CSV attachment in R2
- related_id TEXT NULL                                 -- quote_id / export job id
- error TEXT NULL
- attempts INTEGER NOT NULL DEFAULT 0
- created_at INTEGER NOT NULL
- sent_at INTEGER NULL
INDEX ix_outbox_status ON email_outbox(status, created_at)
INDEX ix_outbox_user ON email_outbox(user_id)
  (No reminders here — Alerts are in-app only, per the decision.)

tax_settings  (per profile; AU GST 10% + FY config)
- id TEXT PRIMARY KEY
- user_id TEXT NOT NULL REFERENCES users(id)
- profile_id TEXT NOT NULL REFERENCES profiles(id)
- gst_rate_bps INTEGER NOT NULL DEFAULT 1000           -- basis points: 1000 = 10.00%
- financial_year_start_month INTEGER NOT NULL DEFAULT 7 -- AU FY starts July
- meals_deductible_pct INTEGER NOT NULL DEFAULT 50     -- the 50% meals rule
- wfh_rate_cents_per_hour INTEGER NOT NULL DEFAULT 67  -- ATO fixed-rate method
- mileage_rate_cents_per_km INTEGER NOT NULL DEFAULT 88
- created_at INTEGER NOT NULL
- updated_at INTEGER NOT NULL
- deleted_at INTEGER NULL
UNIQUE INDEX ux_tax_profile ON tax_settings(profile_id) WHERE deleted_at IS NULL
INDEX ix_tax_user_updated ON tax_settings(user_id, updated_at)

## 9. Sync Support: Columns, Tombstones & Mutation Queue
LOCAL-FIRST contract. Writes hit SwiftData instantly and enqueue locally; the server is the source of truth for conflict resolution.

Sync-support columns on EVERY synced domain table (users, devices, profiles, categories, smart_rules, transactions, line_items, receipt_images, budgets, loyalty_cards, mileage_trips, wfh_logs, quotes, quote_line_items, tax_settings):
- id TEXT PRIMARY KEY        — UUIDv7, generated on-device so offline inserts never collide.
- user_id TEXT NOT NULL      — tenant boundary; the per-user delta partition key.
- created_at INTEGER NOT NULL — epoch ms.
- updated_at INTEGER NOT NULL — epoch ms; THE cursor field and the LWW comparison key. Server stamps a monotonic server-time on accept so a device with a skewed clock can't poison ordering; client updated_at is kept as a tiebreak only.
- deleted_at INTEGER NULL     — soft-delete TOMBSTONE. Row is never hard-deleted on the sync path; deletion is a normal mutation (set deleted_at, bump updated_at) so it propagates to every device. Tombstones are garbage-collected by a server job only after they predate the OLDEST device cursor for that user (so no device misses the delete).

Last-write-wins resolution: on push, the server compares incoming updated_at against the stored row. Higher updated_at wins (server-time authoritative, client-time tiebreak, then id as final deterministic tiebreak). A delete (deleted_at set) competes by its updated_at like any other write — an edit with a newer timestamp can resurrect a row, matching the stated LWW intent.

Pull (delta) protocol — uses ix_*_user_updated everywhere:
  SELECT * FROM <table>
   WHERE user_id = :uid AND updated_at > :cursor
   ORDER BY updated_at, id
   LIMIT :page;   -- page <= a few hundred; respects the 100-bound-param limit by binding few params
The cursor is the max(updated_at) returned. Tombstones (deleted_at NOT NULL) ARE included in the delta so the client can remove them locally. Per-device cursor lives in devices.last_sync_cursor.

mutation_queue  (lives on-device in SwiftData; mirrored server-side as an idempotency log)
- id TEXT PRIMARY KEY               -- client mutation UUID (idempotency key)
- user_id TEXT NOT NULL
- device_id TEXT NOT NULL REFERENCES devices(id)
- entity TEXT NOT NULL              -- table name
- entity_id TEXT NOT NULL           -- target row id
- op TEXT NOT NULL CHECK (op IN ('insert','update','delete'))
- payload_json TEXT NULL            -- changed fields (sparse) for update/insert
- base_updated_at INTEGER NULL      -- the updated_at the client based its edit on (for LWW/debug)
- applied_at INTEGER NULL           -- server: when accepted (NULL = pending/duplicate-safe)
- created_at INTEGER NOT NULL
UNIQUE INDEX ux_mut_idem ON mutation_queue(id)         -- replaying the same mutation is a no-op
INDEX ix_mut_user ON mutation_queue(user_id, created_at)
  The UNIQUE idempotency key makes the offline queue safe to retry: if the network drops mid-push, re-sending the same mutation id is ignored server-side. On-device, the queue drains FIFO; failed items retry with backoff and never block later independent mutations of other entities.

## 10. Indexing Summary & Migration Notes
Every synced table gets the same two-index backbone plus purpose-built read indexes:

Delta-sync backbone (one per synced table):
  ix_<t>_user_updated ON <t>(user_id, updated_at)   — drives every pull query; the single most important index.

Profile-scoped read indexes (for the UI's profile switcher + month picker):
  transactions:   ix_txn_profile_date(profile_id, txn_date) WHERE deleted_at IS NULL
                  ix_txn_profile_month(profile_id, month_key) WHERE deleted_at IS NULL
  budgets:        ix_budget_profile(profile_id, month_key) WHERE deleted_at IS NULL
  mileage_trips:  ix_trip_profile_date(profile_id, trip_date) WHERE deleted_at IS NULL
  quotes:         ix_quote_profile_status(profile_id, status) WHERE deleted_at IS NULL
Partial (WHERE deleted_at IS NULL) indexes keep tombstones out of hot read paths and shrink the index — supported by D1.

FK lookup indexes: line_items(transaction_id), quote_line_items(quote_id), receipt_images(transaction_id), auth_identities(user_id), every profile_id/category_id FK used in joins.

Uniqueness via UNIQUE INDEX (partial where soft-delete applies): users.email, devices.apns_token, quotes.number, wfh_logs(profile_id,log_date), budgets(profile_id,category_id,month_key), receipt_images.r2_key, email_tokens.token_hash, auth_identities(provider,subject), mutation_queue.id.

Migrations:
- Use D1 migrations (wrangler d1 migrations). One forward-only .sql per change; number them 0001_init.sql, 0002_....
- Generated columns added later via ALTER TABLE must be VIRTUAL (STORED only allowed at table-create). month_key and line_total_cents are STORED because they're set at creation.
- After applying index migrations, run `PRAGMA optimize;` (runs ANALYZE) so the planner picks the new indexes.
- Keep all binary in R2; D1 stores only keys (2 MB row cap). 
- Worker enforces tenancy on EVERY query: WHERE user_id = :authedUser. profile_id from the client is filtered, never trusted alone.

Sources:
- https://developers.cloudflare.com/d1/sql-api/sql-statements/
- https://developers.cloudflare.com/d1/best-practices/use-indexes/
- https://developers.cloudflare.com/d1/reference/generated-columns/
- https://developers.cloudflare.com/d1/platform/limits/


### Open questions
- Should categories and smart_rules be seeded per-profile or shared per-user? The schema allows profile_id NULL = shared; confirm the intended default (prototype shows 9 categories at the user level).
- Multi-currency: schema stores ISO-4217 per row, but all rollups (SummaryCard, budgets, GST) assume AUD. Are non-AUD receipts in scope for v1, and if so do you want FX conversion stored at capture time?
- Quote numbering ('SN-0042'): server-assigned sequential per user, or free-form client text? Sequential needs a per-user counter table to stay gap-free offline.
- Loyalty card numbers and APNs tokens are sensitive-ish — do you want app-layer encryption at rest for loyalty_cards.number, or is D1's storage sufficient for v1?
- WFH/mileage rates: store the ATO rate as a snapshot on each trip/log (current design caches rate + claim), or always derive from tax_settings at report time? Confirm whether historical FY rate changes must be preserved.
- Does a personal profile ever need its own tax_settings row, or is tax_settings business-only (currently one row per profile regardless of type)?
- Should email-in receipts that fail DeepSeek extraction still create a transaction (extraction_status='failed') for manual review, or only a receipt_images row until the user acts?

### Risks
- Last-write-wins on updated_at silently loses concurrent edits made on two offline devices to the same record (e.g., two field edits to one transaction) — only field-level merge or a CRDT would prevent it; acceptable for v1 but call it out to the user.
- Client-generated updated_at can be skewed by a wrong device clock; the design relies on the server re-stamping a monotonic server-time on accept. If the worker forgets to do this, a device with a future clock can permanently 'win' and block legitimate edits.
- Soft-delete tombstones accumulate forever unless the GC job (delete rows older than the oldest device cursor) is actually implemented; without it the DB and every delta pull grow unbounded.
- R2 object reclamation after a transaction/image tombstone must wait until all devices have synced the delete; deleting R2 objects eagerly will break offline devices still showing the receipt.
- D1 does not strongly enforce foreign keys across batched statements the way a traditional RDBMS does; integrity depends on the worker wrapping multi-table writes in transactions and on the app always scoping by user_id. A buggy client could orphan line_items/images.
- cat_key and category_id are both stored on transactions for resilience; they can drift if a custom category is re-keyed — the worker must keep them consistent on write.
- budgets and logbook 'spent/claim' values: spent is intentionally computed (not stored) to avoid drift, but claim_cents IS cached on trips/wfh — caches must be recomputed when rate settings change or they go stale.

---

# Snapceipt Backend: Cloudflare Worker (Hono) REST API + Local-First Sync Protocol

## 0. Overview, Stack & Verified Cloudflare Patterns
Snapceipt is a SwiftUI iOS 17+ (SwiftData) receipt app. The backend is a single Cloudflare Worker running Hono. D1 (SQLite) + R2 (object store) are the source of truth; the iOS device is a local-first replica that works fully offline and reconciles via a sync protocol.

Verified-current Cloudflare patterns used (checked against docs dated Feb-Apr 2026):
- wrangler.jsonc (JSON, not TOML — newer features are JSON-only). compatibility_date within ~30 days. Run `wrangler types` to generate the Env interface; never hand-write it.
- Bindings are direct in-process refs (no network hop, no auth): D1 `env.DB`, R2 `env.RECEIPTS`, Workers AI `env.AI`, Email Send `env.SEND_EMAIL` (binding type `send_email`), KV `env.KV` (rate limits + magic-link/nonce store), Secrets via `wrangler secret put`.
- Never store request state in module-level/global variables (isolates are reused across requests → cross-request leaks and 'Cannot perform I/O on behalf of a different request'). Pass state through `c.env` / context.
- Email Send: `import { EmailMessage } from 'cloudflare:email'` + `createMimeMessage()` from `mimetext`, then `await env.SEND_EMAIL.send(msg)`.
- Email-in (Email Routing): export an `email(message, env, ctx)` handler alongside `fetch`. The Worker receives the raw MIME, extracts attachments/inline images.
- Workers AI OCR: `env.AI.run('@cf/meta/llama-3.2-11b-vision-instruct', { messages, image: [...bytes] })` (image as Uint8Array byte array; 128k ctx). Used only for the email-in path (the app path uses on-device Vision OCR).
- R2: small receipt JPEGs (<~5MB) upload through the Worker via `env.RECEIPTS.put()` (simplest, authenticated). Larger/originals can use aws4fetch presigned PUT URLs (do NOT sign Content-Type; sign only host with `signQuery:true`). v1 uses the through-Worker put path.

Sources: developers.cloudflare.com/changelog/post/2026-02-15-workers-best-practices, /workers/best-practices/workers-best-practices, hono.dev/docs/getting-started/cloudflare-workers, /email-routing/email-workers/send-email-workers, /workers-ai/models/llama-3.2-11b-vision-instruct, /r2/api/s3/presigned-urls, api-docs.deepseek.com/guides/json_mode, developer.apple.com/documentation/signinwithapplerestapi/generate-and-validate-tokens.

## 1. AUTH — Sign in with Apple, Magic-Link, Sessions, Devices, Keychain
Two sign-in methods, one session model. All tokens are app-issued JWTs (HS256, secret `JWT_SIGNING_KEY`); Apple/magic-link only bootstrap the first session.

TOKEN MODEL
- Access token (JWT): 15 min TTL. Claims: { sub: userId, sid: sessionId, did: deviceId, iss: 'snapceipt', aud: 'snapceipt-ios', iat, exp, scope:['app'] }. Sent as `Authorization: Bearer <jwt>`.
- Refresh token: opaque 256-bit random, 60-day sliding TTL, ROTATED on every refresh (reuse-detection: a replayed old refresh token revokes the whole session family). Stored hashed (SHA-256) in D1 `sessions`. Bound to deviceId.
- iOS stores BOTH in Keychain, item class kSecClassGenericPassword, `kSecAttrAccessibleAfterFirstUnlock` (sync needs to run from background), `kSecAttrAccessGroup` for the share extension. Never UserDefaults.

(A) SIGN IN WITH APPLE
Client: ASAuthorizationAppleIDProvider, sends a server-generated `nonce` (raw nonce kept on device; sha256(nonce) sent to Apple). POST /v1/auth/apple { identityToken, authorizationCode, rawNonce, fullName?, email? }.
Server verification (exact steps):
1. Fetch Apple JWKS from https://appleid.apple.com/auth/keys (cache in KV ~24h, refresh on kid miss for key rollover).
2. Verify identityToken JWS signature with matching kid (RS256).
3. Assert iss == 'https://appleid.apple.com', aud == bundleId 'com.snapceipt.app', exp not passed, and sha256(rawNonce) == token.nonce (replay protection).
4. `sub` = Apple stable user id → upsert users row (apple_sub unique). Apple sends name/email only on FIRST authorization, so persist them then; later sign-ins omit them.
5. Issue session (see (D)).
Response: { accessToken, refreshToken, expiresIn:900, user:{ id, email, displayName } }.

(B) EMAIL MAGIC-LINK (via Cloudflare Email Send)
- POST /v1/auth/magic-link/request { email }. Server: normalize email, generate 256-bit token, store SHA-256(token) in KV key `ml:<hash>` with 15-min TTL + { email, deviceHint }. Always return 202 (no account enumeration). Send email via `env.SEND_EMAIL` containing a universal link https://snapceipt.app/auth/magic?token=<token> (also a 6-digit OTP fallback for users not on device). Rate-limited: 3/email/hour, 10/IP/hour.
- POST /v1/auth/magic-link/verify { token } (or { email, otp }). Server: hash, look up KV, atomically delete (single-use), upsert user (email unique), issue session. Returns same envelope as Apple.
- The same `env.SEND_EMAIL` binding powers magic-link, accountant exports, and quote sends. allowed_sender_addresses pins 'noreply@snapceipt.app'.

(C) DEVICE REGISTRATION
- Every session is bound to a device. On first sign-in the client generates a UUID `deviceId` (persisted in Keychain) and sends `X-Device-Id` + { deviceName, osVersion, appVersion, apnsToken? }. Server upserts `devices` (PK deviceId, FK userId). APNs token stored here powers budget push alerts (decision: real in v1).
- PUT /v1/devices/me updates apnsToken / appVersion. DELETE /v1/devices/:id (sign out a device → revokes its session family).

(D) SESSION ISSUE / REFRESH / REVOKE
- Issue: create sessions row { id, userId, deviceId, refreshHash, family, createdAt, lastSeenAt, expiresAt }. Return access+refresh.
- POST /v1/auth/refresh { refreshToken } (no bearer needed). Validate hash + not expired + not revoked → ROTATE (new refresh, invalidate old, same family), mint new access. Reuse of a rotated token → revoke entire family, force re-auth (401 + code AUTH_SESSION_REVOKED).
- POST /v1/auth/signout (bearer): revoke current session. Keychain cleared client-side.
- GET /v1/auth/me → current user + active devices.

## 2. SYNC — Local-First Protocol (push/pull, idempotency, LWW, tombstones)
PRINCIPLE: SwiftData is the instant write store. Every user-visible mutation (1) writes to SwiftData synchronously, and (2) appends an OutboxMutation to a local mutation queue. A background SyncEngine drains the queue (push) and applies server deltas (pull). The UI never blocks on network.

SHARED ENTITY ENVELOPE (every syncable row in D1 and SwiftData):
{ id (client-generated UUIDv7 — sortable, no server round-trip), userId, profileId, type, ...fields, updatedAt (server-authoritative ms epoch, set by server on write), createdAt, deletedAt (null | ms epoch — soft-delete tombstone), rev (monotonic per-row int, server-incremented), lastEditedDeviceId }.
Syncable types: transaction, lineItem, profile, category, categoryRule, budget, loyaltyCard, quote, mileageTrip, wfhEntry. (Mileage/WFH ARE synced even though GPS auto-track UI is placeholder — manual entries are real data.)

LOCAL OUTBOX MUTATION (SwiftData @Model):
{ mutationId (UUIDv7, idempotency key — STABLE across retries), entityType, entityId, op ('upsert'|'delete'), payload (full entity snapshot for upsert; just id for delete), baseRev (rev the client last saw, for conflict detection), createdAt, attemptCount, status ('pending'|'inflight'|'acked'|'failed') }.

--- PUSH ---
POST /v1/sync/push
Request:
{ deviceId, mutations: [ { mutationId, entityType, entityId, op, baseRev, updatedAt, payload } ] }  // batch up to 200; ordered but applied per-id LWW
Server per mutation (transactional, all-or-nothing per row):
1. Idempotency: if `processed_mutations` already has mutationId → return its prior result (no-op replay). Guarantees at-least-once delivery is safe.
2. Ownership: entity.userId must == JWT.sub else REJECTED_FORBIDDEN.
3. LWW resolve on updatedAt: if server.updatedAt > incoming.updatedAt → server wins (incoming dropped, server row echoed back as the winner). If incoming newer or equal-with-higher-deviceId tiebreak → apply, set rev=server.rev+1, updatedAt=server-clock-now, lastEditedDeviceId=deviceId. Delete = set deletedAt (tombstone), never hard-delete.
4. Record mutationId in processed_mutations (TTL 30d).
Response:
{ results: [ { mutationId, status: 'applied'|'conflict'|'duplicate'|'rejected', reason?, entity: {<server-canonical row incl. rev/updatedAt>} } ], serverCursor: '<opaque>' }
Client: on 'applied'/'duplicate' delete outbox row + write back server rev/updatedAt. On 'conflict' OVERWRITE local with returned server entity (LWW already decided; UI shows a non-blocking 'updated elsewhere' toast). On 'rejected' surface error, mark failed.

--- PULL (delta) ---
GET /v1/sync/pull?cursor=<opaque>&limit=500
Cursor = opaque base64 of { ts: lastUpdatedAtSeen, id: lastIdSeen } (composite keyset, stable under concurrent writes). First sync: omit cursor → full snapshot paginated.
Server: SELECT * FROM <all types> WHERE userId=? AND (updatedAt,id) > (cursor.ts,cursor.id) ORDER BY updatedAt,id LIMIT n. Tombstones (deletedAt != null) ARE returned so deletes propagate.
Response:
{ changes: [ {<full entity envelope, may have deletedAt>} ], nextCursor: '<opaque>', hasMore: true|false, serverTime: <ms> }
Client: apply each change with LWW vs local (if local has unsynced newer edit in outbox for same id, KEEP local — outbox is source of pending truth; otherwise upsert/tombstone). Persist nextCursor only after the whole page commits (crash-safe). Loop until hasMore=false.

CONFLICT HANDLING SUMMARY: pure LWW on updatedAt with deviceId tiebreak; no merge for scalar fields. lineItems are children of a transaction and replaced wholesale with the parent (parent owns its items, so no per-item conflict). Soft-delete always loses to a newer non-deleted edit (undelete is possible if a device edits after another deletes — last writer wins, matching user mental model). Clock skew is neutralized because the SERVER stamps updatedAt on every accepted write; client updatedAt is only a tiebreak hint for ordering within a push batch.

Guarantees: idempotent (mutationId), at-least-once safe, convergent (all devices reach identical state after draining), offline-complete (queue survives app kills via SwiftData).

## 3. RESOURCE ENDPOINTS
All under /v1, all require Bearer auth except where noted. Mutating resource endpoints exist for web/admin/non-sync clients, but the iOS app drives nearly everything through /v1/sync/* — these REST routes share the same D1 tables and envelope.

CORE SYNCABLE RESOURCES (standard REST: GET list, GET :id, POST, PATCH :id, DELETE :id soft-delete):
- /transactions — { id, profileId, merchant, amount (Decimal, signed: negative=expense), currencyCode:'AUD', category, purchaseDate, gst (Decimal|null, AU 10%), gstIncluded (bool), deductiblePercent (0-100|null), note, imageKey (R2 key|null), rawOcrText, source ('scan'|'manual'|'email'), lineItems:[{id,name,price}], ...envelope }. Query: ?profileId=&from=&to=&kind=expense|income&category=&q=.
- /profiles — { id, name, type ('personal'|'business'), abn (string|null), gstRegistered (bool), palette, ...envelope }. Multi-profile per user; transactions/budgets/etc. are profile-scoped.
- /categories — { id, profileId, label, icon, tint, ...envelope }.
- /categories/rules — { id, profileId, matchTerms:[string], category, deductiblePercent, note, ...envelope }. Applied client-side and server-side (on /extract + email-in) to auto-categorize.
- /budgets — { id, profileId, category|null(overall), period ('monthly'), limit (Decimal), ...envelope }. REAL in v1. Push alerts: a Worker Cron (scheduled handler) + on-write check computes spend vs limit; at 80%/100% sends APNs to the profile's devices (uses devices.apnsToken). PushNotification path documented in §4.
- /loyalty — { id, label, brand, barcodeValue, barcodeFormat ('code128'|'qr'|'ean13'|'pdf417'), color, memberNumber, ...envelope }. REAL barcodes in v1; barcodeValue+format rendered on-device.
- /quotes — { id, profileId, number ('SN-####'), client, items:[{name,qty,price}], subtotal, gstApplied (bool), gst, total, validDays:14, status ('draft'|'sent'|'accepted'), ...envelope }. POST /quotes/:id/send → renders PDF, emails client via env.SEND_EMAIL.
- /mileage — { id, profileId, fromLabel, toLabel, purpose, km (Decimal), business (bool), tripDate, ...envelope }. Manual entries synced; GPS auto-track is UI placeholder (no endpoint, no background location in v1).
- /wfh — { id, profileId, logDate, hours (Decimal), note, ...envelope }. AU fixed-rate (67c/hr) computed in reports.

PLACEHOLDER (UI-only, NO backend in v1): connected banks / reconcile — return 501 NOT_IMPLEMENTED if called, so the UI can degrade gracefully.

SPECIAL ENDPOINTS:
- POST /v1/images — multipart or raw body, the cropped JPEG from VisionKit. Worker validates (image/jpeg|png, <=8MB), writes `env.RECEIPTS.put('u/{userId}/{uuid}.jpg', body, { httpMetadata })`, returns { imageKey, getUrl }. GET /v1/images/:key streams from R2 (auth + ownership check on key prefix). Receipt rows store imageKey, not bytes (SwiftData keeps a local copy for offline).
- POST /v1/extract — body { rawText, profileId, locale:'en-AU' }. The iOS app runs on-device Vision OCR (ReceiptScanner.swift) then posts the text. Worker calls DeepSeek deepseek-v4-flash with response_format:{type:'json_object'} (JSON mode requires the word 'json' + a schema example in the prompt; set max_tokens to avoid truncation; retry once on empty content — known DeepSeek quirk). System prompt extracts { merchant, purchaseDate (ISO8601), currencyCode (default AUD), total, gst (10% logic — if total includes GST, gst=total/11), gstIncluded, lineItems:[{name,price}], suggestedCategory, deductiblePercent } and applies the user's category rules. Returns the structured ParsedReceipt. Rate-limited per user. (Client never holds the DeepSeek key — matches the ReceiptScanner.swift LLMParser comment.)
- POST /v1/export — body { profileId, format ('pdf'|'csv'|'accountant'), from, to, kind? }. pdf/csv → generate + return a short-lived R2 download URL. 'accountant' → emails the PDF+CSV to a saved accountant address via env.SEND_EMAIL (send-to-accountant). NO emailed reminders ever (alerts stay in-app, per decision).
- POST /v1/email-in (Email Routing handler, NOT a fetch route) — the exported `email(message, env, ctx)` handler. Parses inbound MIME, extracts the receipt image attachment, runs Workers AI OCR `@cf/meta/llama-3.2-11b-vision-instruct` (image as byte array) to get rawText, feeds the SAME DeepSeek extractor, creates a transaction (source:'email') owned by the user matched via the verified sender/forwarding address, uploads image to R2. The new row flows to devices on next /sync/pull. Replies a confirmation email.

## 4. Cross-Cutting: Middleware, Error Envelope, Versioning, Rate Limiting, wrangler
HONO APP SHAPE
```ts
type Bindings = { DB: D1Database; RECEIPTS: R2Bucket; AI: Ai; KV: KVNamespace; SEND_EMAIL: SendEmail; JWT_SIGNING_KEY: string; DEEPSEEK_API_KEY: string; APPLE_BUNDLE_ID: string }
const app = new Hono<{ Bindings: Bindings; Variables: { userId: string; deviceId: string } }>()
app.use('*', requestId(), logger(), cors())
app.use('/v1/*', rateLimit())
app.use('/v1/*', auth())                 // skips /v1/auth/* and /v1/email-in
const v1 = new Hono<...>(); v1.route('/transactions', txnRoutes); /* ... */ app.route('/v1', v1)
export default { fetch: app.fetch, email: emailIn, scheduled: budgetCron }
```

AUTH MIDDLEWARE: extract Bearer, verify JWT (HS256, check iss/aud/exp), set c.set('userId'/'deviceId'). On failure throw HTTPException(401). Public-path allowlist for /v1/auth/* and the email handler. Every D1 query is scoped `WHERE userId = c.get('userId')` (tenant isolation — never trust client-sent userId).

ERROR ENVELOPE (uniform, via app.onError):
{ error: { code: 'AUTH_INVALID_TOKEN'|'VALIDATION_FAILED'|'NOT_FOUND'|'FORBIDDEN'|'RATE_LIMITED'|'CONFLICT'|'NOT_IMPLEMENTED'|'INTERNAL', message, details?, requestId } } with matching HTTP status. Success bodies are the raw resource/envelope (no wrapper) so clients decode directly. Validation via zod (`@hono/zod-validator`) on every body/query.

VERSIONING: URL-prefix /v1. Additive changes stay in v1; breaking changes → /v2 (run side-by-side). Clients send X-App-Version; server can soft-deprecate via a `Warning` header and a `minSupportedVersion` field on /v1/auth/me to trigger force-upgrade UI.

RATE LIMITING: KV-based fixed-window per { userId|IP, route-class }. Tiers: auth/magic-link 3/email/hr + 10/IP/hr; /extract & /export (cost: DeepSeek/AI) 60/user/hr; /sync/push & /sync/pull 600/user/hr (generous — it's the hot path); default 300/user/min. 429 with Retry-After + RATE_LIMITED envelope. (Optionally upgrade to Cloudflare's native Rate Limiting binding later.)

PUSH ALERTS (budgets, real in v1): `scheduled` cron (e.g. hourly) + post-write hook recompute profile spend; threshold crossings send APNs via token from `devices`. Stored, idempotent per (budgetId, threshold, period) so a user isn't spammed.

WRANGLER (wrangler.jsonc, verified shape):
```jsonc
{ "name": "snapceipt-api", "main": "src/index.ts", "compatibility_date": "2026-05-15", "compatibility_flags": ["nodejs_compat"],
  "observability": { "enabled": true },
  "d1_databases": [{ "binding": "DB", "database_name": "snapceipt", "database_id": "..." }],
  "r2_buckets": [{ "binding": "RECEIPTS", "bucket_name": "snapceipt-receipts" }],
  "kv_namespaces": [{ "binding": "KV", "id": "..." }],
  "ai": { "binding": "AI" },
  "send_email": [{ "name": "SEND_EMAIL", "allowed_sender_addresses": ["noreply@snapceipt.app"] }],
  "triggers": { "crons": ["0 * * * *"] } }
```
Secrets (`wrangler secret put`): JWT_SIGNING_KEY, DEEPSEEK_API_KEY, APPLE_BUNDLE_ID, APNS auth key. `wrangler types` generates Env. Email Routing (inbound) is configured in the dash/Email Routing to route the receipt-intake address to this Worker.


### Open questions
- Confirm the exact DeepSeek production model ID ('deepseek-v4-flash' vs the API's published name) and base URL/auth header, and whether it supports strict JSON schema or only json_object mode.
- Which inbound address scheme for email-in receipts: a per-user alias (e.g. u-<token>@in.snapceipt.app) for unambiguous owner matching, or a single shared address relying on verified sender lookup? Per-user alias is safer for ownership attribution.
- Is Cloudflare Email Service approved/enabled on the account for outbound sending, and is snapceipt.app verified with SPF/DKIM/DMARC? If not, what is the interim email provider?
- Should magic-link issue a session for the SAME device that requested it only (tighter security) or any device that opens the link? Current design allows any device opening the universal link; confirm desired strictness.
- Retention policy for soft-delete tombstones and processed_mutations records (proposed 30d) — long enough for offline devices to catch up but bounded; confirm acceptable max offline window.
- Free-tier vs paid: Workers AI, D1, R2, and Email Send all have free-tier caps; confirm expected volume so rate limits and the AI OCR (email-in) path stay within budget.
- Do quotes/invoices need their own sequence authority on the server (to avoid duplicate SN-#### numbers across offline devices), or is client-generated numbering with server reconciliation acceptable?
- Should the placeholder GPS mileage and connected-banks UI hit a 501 endpoint (as designed) or be fully client-stubbed with no network call at all to avoid confusing telemetry?

### Risks
- DeepSeek model naming: the decision specifies 'deepseek-v4-flash' and docs reference response_format json_object plus deepseek-v4-flash/pro tiers, but the exact public model string and base URL should be confirmed against DeepSeek's live API console before coding — JSON mode also intermittently returns empty content, so a single retry is mandatory.
- Cloudflare Email SENDING (env.SEND_EMAIL / Cloudflare Email Service) is recent (public beta as of 2026) and may have per-account enablement, verified-domain, and SPF/DKIM/DMARC requirements; deliverability of magic-link and accountant exports must be validated, and a fallback provider (e.g. Resend/Postmark) considered if beta limits bite.
- Sign in with Apple sends name/email ONLY on first authorization; if that first response is lost (app crash before persisting), the data cannot be re-fetched from Apple and must be collected from the user manually.
- Workers AI vision model image input format (byte array vs base64) is not fully documented on the model page; the exact env.AI.run image parameter shape for @cf/meta/llama-3.2-11b-vision-instruct must be confirmed by testing before relying on it for email-in OCR.
- LWW silently discards concurrent edits to the same field across devices; acceptable for a single-user receipt app but will surprise users who edit the same transaction on two offline devices — the 'updated elsewhere' toast partially mitigates but there is no field-level merge.
- D1 has size/row limits and is SQLite — very large accounts (tens of thousands of transactions + full-table delta scans) need the (updatedAt,id) keyset index and pagination to stay performant; verify D1 query limits for the pull scan across multiple entity tables.
- R2 through-Worker upload caps effective body size by Worker limits; large original-resolution scans may need the aws4fetch presigned-PUT direct path sooner than v1 plans.
- APNs push for budget alerts requires an APNs auth key + token-based JWT signing inside the Worker; ensure the key is stored as a secret and the p8/JWT signing works under the Workers runtime crypto APIs.

---

# Snapceipt Receipt-Extraction Pipeline Contract (DeepSeek V4 Flash + Cloudflare Workers AI)

## 0. Verified facts (web search, May 2026)
DeepSeek V4 (verified against api-docs.deepseek.com):
- Base URL: https://api.deepseek.com
- Endpoint: POST /chat/completions (OpenAI-compatible; Anthropic-compatible endpoint also exists)
- Model: deepseek-v4-flash (cheap/fast tier; deepseek-v4-pro is the reasoning tier). Replaces deprecated deepseek-chat/deepseek-reasoner (deprecation 2026-07-24).
- Auth: HTTP header Authorization: Bearer <DEEPSEEK_API_KEY>
- JSON mode: response_format={"type":"json_object"}. Three documented requirements/caveats: (1) the word "json" MUST appear in the system or user prompt or the request errors; (2) JSON mode guarantees syntactically valid JSON but does NOT enforce a schema (so we validate ourselves); (3) the API may occasionally return empty content — mitigate via prompt and retry.
- Context window: 1M tokens (OCR text is tiny relative to this).

Cloudflare Workers AI OCR/vision (verified against developers.cloudflare.com):
- Recommended model: @cf/meta/llama-3.2-11b-vision-instruct (multimodal, optimized for visual recognition/image reasoning/captioning; best generally-available vision model on Workers AI for reading receipt images). LLaVA (@cf/llava-hf/llava-1.5-7b-hf) and Llama 4 Scout are alternatives.
- Invocation: await env.AI.run("@cf/meta/llama-3.2-11b-vision-instruct", { messages, image }). image accepts a base64 data URL string (e.g. "data:image/png;base64,...") or a byte array; prompt/messages carry the instruction; max_tokens default 256 (raise it for full receipts).
- Context window: 128,000 tokens. Binding declared in wrangler.jsonc as { "ai": { "binding": "AI" } }.
- Pricing: Neurons model, $0.011 per 1,000 Neurons, 10,000 Neurons/day free; Cloudflare is migrating to unit-based pricing (per model task/size + input/output tokens). Treat exact per-image cost as approximate and meter it.

Note: deepseek-v4-flash is text-only here. Both paths converge to text -> the SAME DeepSeek extractor. On-device uses Apple Vision OCR; email-in uses Workers AI vision as the OCR substitute. This keeps one prompt + one validator for both paths.

## 1. POST /extract — request schema
The /extract endpoint runs on a Cloudflare Worker. It is path-agnostic to the OCR source: the iOS app sends Vision OCR text directly; the email Worker first runs Workers AI vision, then calls the same internal extractor function (or re-POSTs to /extract). Request:

POST /extract
Content-Type: application/json
Authorization: Bearer <app session/device token>   // app auth, NOT the DeepSeek key

{
  "$schema": "https://snapceipt.app/schemas/extract-request.v1.json",
  "type": "object",
  "required": ["ocrText", "source"],
  "additionalProperties": false,
  "properties": {
    "ocrText":        { "type": "string", "minLength": 1, "maxLength": 50000, "description": "Raw OCR text (Apple Vision on-device, or Workers AI vision for email-in). Newlines preserved." },
    "source":         { "type": "string", "enum": ["ios_vision", "email_workers_ai"] },
    "defaultCurrency":{ "type": "string", "pattern": "^[A-Z]{3}$", "default": "AUD" },
    "locale":         { "type": "string", "default": "en-AU", "description": "Drives date format disambiguation (AU = DD/MM/YYYY) and GST defaults." },
    "capturedAt":     { "type": "string", "format": "date-time", "description": "Client capture time; fallback for relative/ambiguous receipt dates." },
    "requestId":      { "type": "string", "format": "uuid", "description": "Idempotency + tracing key." },
    "ocrMeta": {
      "type": "object", "additionalProperties": false,
      "properties": {
        "ocrConfidence": { "type": ["number","null"], "minimum": 0, "maximum": 1, "description": "Mean confidence from the OCR engine, if available. Feeds the blended confidence in section 4." },
        "blockCount":    { "type": ["integer","null"], "minimum": 0 }
      }
    }
  }
}

## 1b. POST /extract — response schema
HTTP 200 with this envelope. The receipt object is exactly the required field set. needsReview and confidence are computed by the Worker (section 4), not trusted blindly from the model.

{
  "$schema": "https://snapceipt.app/schemas/extract-response.v1.json",
  "type": "object",
  "required": ["requestId", "receipt", "meta"],
  "additionalProperties": false,
  "properties": {
    "requestId": { "type": "string", "format": "uuid" },
    "receipt": {
      "type": "object",
      "required": ["merchant","date","currencyCode","total","tax","gst","category","deductible","lineItems","confidence","needsReview"],
      "additionalProperties": false,
      "properties": {
        "merchant":     { "type": "string", "minLength": 1 },
        "date":         { "type": "string", "format": "date", "description": "ISO 8601 calendar date YYYY-MM-DD." },
        "currencyCode": { "type": "string", "pattern": "^[A-Z]{3}$", "default": "AUD", "description": "ISO 4217." },
        "total":        { "type": "number", "minimum": 0 },
        "tax":          { "type": ["number","null"], "minimum": 0, "description": "Total tax of any kind on the receipt; null if none/unknown." },
        "gst":          { "type": ["number","null"], "minimum": 0, "description": "AU GST component (10%). Inferred as round(total/11,2) when AUD and not explicitly printed; null if clearly GST-free." },
        "category":     { "type": "string", "enum": ["groceries","dining","transport","utilities","health","entertainment","shopping","travel","other"] },
        "deductible":   { "type": ["integer","null"], "minimum": 0, "maximum": 100, "description": "Estimated business-deductible percentage; null when not determinable." },
        "lineItems": {
          "type": "array",
          "items": {
            "type": "object",
            "required": ["name","price"],
            "additionalProperties": false,
            "properties": {
              "name":  { "type": "string", "minLength": 1 },
              "price": { "type": "number" }
            }
          }
        },
        "confidence":   { "type": "number", "minimum": 0, "maximum": 1 },
        "needsReview":  { "type": "boolean" }
      }
    },
    "meta": {
      "type": "object",
      "required": ["model","source","latencyMs","attempts"],
      "additionalProperties": false,
      "properties": {
        "model":         { "type": "string", "const": "deepseek-v4-flash" },
        "ocrModel":      { "type": ["string","null"], "description": "@cf/meta/llama-3.2-11b-vision-instruct for email path, null for ios_vision." },
        "source":        { "type": "string", "enum": ["ios_vision","email_workers_ai"] },
        "latencyMs":     { "type": "integer", "minimum": 0 },
        "attempts":      { "type": "integer", "minimum": 1, "description": "DeepSeek call attempts incl. JSON-repair retries." },
        "reviewReasons": { "type": "array", "items": { "type": "string" }, "description": "Human-readable flags driving the review screen (section 4)." },
        "fieldConfidence": { "type": "object", "description": "Optional per-field 0-1 scores for UI field highlighting.", "additionalProperties": { "type": "number" } }
      }
    }
  }
}

The 9 categories are fixed: groceries, dining, transport, utilities, health, entertainment, shopping, travel, other.

## 2. EXACT DeepSeek prompts (system + user)
Sent as the messages array to POST /chat/completions. The word "json" appears in the system prompt (required by JSON mode). Temperature 0 (deterministic), max_tokens 1500.

SYSTEM PROMPT (verbatim):
---
You are a precise receipt data extractor for an Australian expense app. You receive the raw, noisy OCR text of a single retail receipt and you return ONLY a single JSON object. No prose, no markdown, no code fences — JSON only.

The OCR text is noisy: characters may be wrong (O/0, I/1/l, S/5, B/8), lines may be out of order, currency symbols may be garbled, and totals may appear multiple times (subtotal, total, amount paid, change). Reason carefully before choosing values.

Return EXACTLY this JSON shape and nothing else:
{
  "merchant": string,
  "date": "YYYY-MM-DD",
  "currencyCode": "AUD" | other ISO 4217 code,
  "total": number,
  "tax": number | null,
  "gst": number | null,
  "category": one of ["groceries","dining","transport","utilities","health","entertainment","shopping","travel","other"],
  "deductible": integer 0-100 | null,
  "lineItems": [ { "name": string, "price": number } ],
  "confidence": number 0.0-1.0,
  "needsReview": boolean
}

Rules:
- merchant: the store/business name, cleaned of OCR noise. Title case. If unreadable, use "Unknown".
- date: the transaction date as ISO 8601 YYYY-MM-DD. Australian receipts use DD/MM/YYYY — interpret day-first. If the year is 2 digits assume 20YY. If no date is present, use the provided capture date.
- currencyCode: ISO 4217. Default to "AUD" unless the receipt clearly shows another currency.
- total: the final amount the customer paid (grand total / amount paid / balance due), NOT subtotal and NOT change given.
- tax: total tax shown of any kind, else null.
- gst: the Australian GST (10%) component. If GST is printed, use it. If currencyCode is AUD and the receipt is taxable but GST is not printed, infer it as round(total / 11, 2) (GST is 1/11 of a GST-inclusive total). If the receipt is clearly GST-free (e.g. most basic groceries, fresh food) or non-AUD, use null.
- category: choose the single best fit from the 9 allowed values. Use "other" only when nothing fits.
- deductible: estimate the percentage likely claimable as a business expense for a typical sole trader (e.g. work tools/software ~100, business meals ~50, personal groceries ~0). Use null if you cannot reasonably estimate.
- lineItems: individual purchased items with prices. Omit subtotal/tax/total/discount/change lines. Empty array if none are legible.
- confidence: your own 0.0-1.0 confidence that the extracted fields are correct given the OCR noise.
- needsReview: true if confidence < 0.8, the total is missing/ambiguous, the date is guessed, or line items do not plausibly sum near the total; otherwise false.

Never invent a total. If the total cannot be determined, set total to 0, confidence below 0.5, and needsReview to true. Output JSON only.
---

USER PROMPT (template; server fills the variables):
---
Receipt OCR source: {{source}}
Default currency: {{defaultCurrency}}
Locale: {{locale}}
Capture date (fallback if no date on receipt): {{capturedAt}}

Raw OCR text:
<<<
{{ocrText}}
>>>

Extract the receipt now and respond with the JSON object only.
---

## 3. JSON-mode config, schema validation, retry-on-invalid-JSON
DeepSeek request body (per call):
{
  "model": "deepseek-v4-flash",
  "messages": [ {system}, {user} ],
  "response_format": { "type": "json_object" },
  "temperature": 0,
  "max_tokens": 1500,
  "stream": false
}
Headers: Authorization: Bearer <DEEPSEEK_API_KEY> (from Worker secret), Content-Type: application/json.

Validation: response_format json_object guarantees only that the string parses — NOT that it matches our shape — so the Worker runs a strict validator (Zod or Ajv compiled from the section 1b receipt schema) on the parsed object. Validation also coerces/normalizes: trim merchant, uppercase currencyCode, clamp deductible to 0-100, round money to 2 dp, default currencyCode to defaultCurrency when missing.

Retry ladder (max 3 DeepSeek attempts total, exponential backoff 250ms/1s):
1. Attempt 1: full prompt as above.
2. On JSON.parse failure, empty content (documented DeepSeek edge case), or schema-validation failure: Attempt 2 appends a corrective user message — "Your previous reply was not valid against the required schema (error: <validator message>). Return ONLY a corrected JSON object matching the exact shape. JSON only." plus the offending raw text. This handles both malformed JSON and valid-JSON-wrong-shape.
3. Attempt 3: same correction, and strip code fences / extract the largest {...} substring before re-parsing (defensive against stray markdown).
4. All 3 fail -> return HTTP 422 with a minimal safe receipt: merchant "Unknown", total 0, currencyCode defaultCurrency, all nullable fields null, confidence 0, needsReview true, plus meta.reviewReasons=["extraction_failed"]. The client never crashes; the user just lands on a fully manual review screen.

Transport errors (5xx/timeout from DeepSeek) are retried within the same ladder; a 429 backs off and surfaces a transient 503 to the client if exhausted. Hard timeout 20s per DeepSeek call.

## 4. confidence / needsReview logic (review screen + the "98% match" moment)
Do not trust the model's self-reported confidence alone. The Worker computes a blended confidence and a deterministic needsReview, and emits reviewReasons for the UI.

Blended confidence:
  finalConfidence = clamp(
     0.55 * modelConfidence
   + 0.25 * ocrConfidence (from ocrMeta; treat null as 0.7 neutral)
   + 0.20 * arithmeticConsistency, 0, 1)
where arithmeticConsistency = 1 - min(1, |sum(lineItems.price) - (total - (gst||0))| / max(total,1)). I.e. line items + GST should reconcile to total; large mismatch drags confidence down.

needsReview = true if ANY of (each pushes a string into reviewReasons):
- finalConfidence < 0.80                         -> "low_confidence"
- total <= 0 or total missing                    -> "missing_total"
- date was absent on receipt (fell back to capturedAt) -> "guessed_date"
- currencyCode != defaultCurrency                -> "foreign_currency"
- lineItems empty on a multi-line receipt        -> "no_line_items"
- arithmeticConsistency < 0.85                    -> "totals_dont_reconcile"
- merchant == "Unknown"                           -> "unknown_merchant"
- gst inferred (not printed) on a high-value receipt -> "gst_inferred" (soft; informational, doesn't force review on its own)

Review screen behaviour:
- needsReview true -> open the review screen with the flagged fields highlighted (using fieldConfidence + reviewReasons). User confirms/edits; corrections can be logged to improve prompts.
- needsReview false -> skip straight to saved, and show the hero confirmation: "98% match". The displayed percent = round(finalConfidence * 100). Because finalConfidence blends model + OCR + arithmetic reconciliation, a 98% is only shown when all three agree — making the moment trustworthy rather than a hollow LLM self-grade. Cap the celebratory display at 99% (never show 100%) so the number reads as a real confidence estimate, not a guarantee.

## 5. Email-in path: Workers AI OCR step + error handling
Flow: Cloudflare Email Routing delivers the message to an email Worker (or Agents SDK email handler). The Worker extracts the first image attachment, runs Workers AI vision to get OCR text, then calls the same DeepSeek extractor (section 2/3).

OCR step (exact binding usage):
  // wrangler.jsonc: { "ai": { "binding": "AI" }, "send_email": [...] }
  const dataUrl = `data:${att.contentType};base64,${att.base64}`;  // from parsed MIME attachment
  const ocr = await env.AI.run("@cf/meta/llama-3.2-11b-vision-instruct", {
    messages: [
      { role: "system", content: "You are an OCR engine. Transcribe ALL text visible in this receipt image exactly as printed, line by line, preserving order and numbers. Output only the transcribed text, no commentary." },
      { role: "user", content: "Transcribe this receipt image." }
    ],
    image: dataUrl,
    max_tokens: 1024   // raise from the 256 default so long receipts aren't truncated
  });
  const ocrText = ocr.response;
Then POST {ocrText, source:"email_workers_ai", defaultCurrency:"AUD", capturedAt:<email Date header>} to the internal extractor.

Error handling (email-in is async/no live user, so be tolerant and notify):
- No image attachment / unsupported type (only image/png,image/jpeg,image/webp,image/heic; reject application/pdf here or pre-rasterize) -> reply-email: "We could not find a receipt image in your email." Stop.
- Attachment too large (cap ~10MB; reject before AI.run to avoid wasted Neurons) -> reply asking for a smaller/clearer photo.
- AI.run throws or returns empty/whitespace text -> retry once; if still empty, create a manual-entry receipt stub and email the user a deep link to finish it in-app. Never silently drop.
- Multiple images -> process each as a separate receipt (loop), or take the first and note others; pick one policy and document it.
- Idempotency: key on Message-ID so retried email deliveries don't create duplicate receipts.
- After successful extract, send a confirmation email summarizing merchant/total/category and a link to review if needsReview is true.
- Wrap the whole handler so any unhandled error still sends the user a friendly failure email rather than bouncing the message.

## 6. Cost / latency / security
Cost:
- DeepSeek deepseek-v4-flash is the cheap tier with a 1M context; receipt OCR text is tiny (hundreds of tokens in, <1500 out), so per-extract LLM cost is fractions of a cent. temperature 0 + tight max_tokens + retries-only-on-failure keeps spend predictable. Meter tokens per requestId.
- Workers AI vision (email path only) is billed in Neurons ($0.011/1,000 Neurons; 10,000 Neurons/day free; migrating to unit-based per-token/per-task pricing). A single receipt image is well within the free daily tier at low volume; budget and alert on Neuron usage as email volume grows. The iOS path uses free on-device Apple Vision OCR, so it incurs only the DeepSeek call.
- Optimization: cache by content hash of ocrText (idempotency + dedupe re-submits). Reserve deepseek-v4-pro as an optional escalation only when finalConfidence is very low and the receipt is high-value.

Latency:
- iOS path: Vision OCR on-device (sub-second) + one DeepSeek flash call (~1-3s typical) -> show optimistic UI / spinner; 20s hard timeout.
- Email path: adds the Workers AI vision call (a few seconds) but is asynchronous, so latency is non-blocking; confirm by email.
- Single DeepSeek round-trip on the happy path; retries add latency only on the rare invalid-JSON/empty-content case.

Security:
- DEEPSEEK_API_KEY lives ONLY as a Cloudflare Worker secret (wrangler secret put DEEPSEEK_API_KEY) — never in the iOS app, repo, wrangler.jsonc vars, or client responses. The app authenticates to /extract with its own session/device token; the Worker holds and uses the DeepSeek bearer key server-side.
- The Workers AI binding (env.AI) needs no key in code; access is via the platform binding.
- Validate/limit request size (ocrText maxLength 50000) and rate-limit /extract per device to prevent abuse-driven LLM spend.
- PII: receipts contain personal/financial data. Use HTTPS end-to-end, don't log raw ocrText or full responses in plaintext (log requestId + metrics only), and confirm DeepSeek data-retention terms for the AU user base; prefer the on-device OCR path so raw images never leave the phone.
- Email path: verify SPF/DKIM/DMARC via Email Routing, sanitize attachments, enforce the size/type caps before invoking AI.run.


### Open questions
- Should the email-in path process every image attachment as a separate receipt, or only the first? The design assumes one-per-email by default but supports a loop.
- Are PDFs expected via email (many merchants email PDF tax invoices)? Llama 3.2 Vision takes images; PDFs need rasterization or a different parser before OCR.
- Should deductible default by category (e.g. a per-category baseline table) when the model returns null, or stay null and force user input? Affects how often needsReview fires.
- Does the AU compliance requirement need the raw image/PDF retained as the tax-invoice evidence (ATO substantiation), and for how long? This drives R2 storage + retention policy beyond just the extracted JSON.
- What is the app-auth scheme for /extract (per-user JWT, device attestation)? Section 6 assumes a session/device token but the exact mechanism is unspecified.
- Should very-low-confidence high-value receipts auto-escalate from deepseek-v4-flash to deepseek-v4-pro, and what value threshold triggers it?

### Risks
- deepseek-v4-flash is text-only in this design; it does not see the receipt image. Extraction quality is bounded by OCR quality (Apple Vision on-device, Llama 3.2 Vision for email). If receipts are very noisy, consider sending the image directly to a multimodal model instead of OCR-then-text.
- DeepSeek JSON mode guarantees valid JSON syntax but NOT schema conformance, and docs warn it can occasionally return empty content — the section 3 validate+retry ladder is mandatory, not optional. Skipping it will cause intermittent extraction failures.
- Cloudflare is migrating Workers AI off Neurons to unit-based (per-token/per-task) pricing; the $0.011/1,000 Neurons figure and free 10,000/day tier may change. Re-confirm current pricing before forecasting email-path cost at scale.
- GST inference round(total/11,2) assumes a fully GST-inclusive taxable supply. Mixed baskets (GST-free fresh food + taxable items at a supermarket) will be over-estimated. For ATO-grade accuracy, prefer printed GST and flag inferred GST for review.
- deepseek-chat / deepseek-reasoner deprecate 2026-07-24; ensure nothing falls back to those names. Pin model strings in config so the deprecation is a single-line change.
- Workers AI vision max_tokens defaults to 256 — long receipts will be silently truncated if not raised (set to ~1024 as shown). The exact byte-vs-base64 image input format should be confirmed against the current Cloudflare model schema during implementation.
- ISO 8601 'date' as YYYY-MM-DD vs full date-time: the schema uses calendar date; ensure clients don't send/expect timezones on the receipt date field.

---

# Snapceipt Cloudflare Email + R2 Layer — Design Spec (v1)

## 0. Verified platform facts (May 2026)
All design choices below are grounded in current Cloudflare behaviour, verified via web search + the cloudflare-email-service skill on 2026-05-30:

- EMAIL SEND: Use Cloudflare Email Service's native Workers `send_email` binding (no API keys). Launched private beta Sep 2025; it unifies Email Routing + Email Sending. MailChannels' free Workers path was deprecated Aug 2024 — do NOT build on MailChannels. Domain must be onboarded first: `npx wrangler email sending enable snapceipt.app`. SPF + DKIM are auto-configured on onboarding.
- EMAIL RECEIVE: Workers `email(message, env, ctx)` handler. `message.raw` is a single-use `ReadableStream` — buffer once with `await new Response(message.raw).arrayBuffer()`. Parse MIME with `postal-mime`. Subaddressing (RFC 5233 `user+detail@`) is supported and the full localpart (incl. `+detail`) is readable in the Email Worker via `message.to`. Catch-all -> Worker routing is supported.
- WORKERS AI OCR: `@cf/meta/llama-3.2-11b-vision-instruct`. Image is passed as a JS array of bytes: `image: [...new Uint8Array(arrayBuffer)]`, plus a `prompt` string. (A llava fallback `@cf/llava-hf/llava-1.5-7b-hf` uses the same shape.)
- R2: Worker binding `env.BUCKET.get/put/head/delete`. Presigned URLs (S3 API via `aws4fetch`) support `X-Amz-Expires` from 1 second to 7 days (604,800 s) max. Lifecycle rules + object lifecycle config are managed per-bucket.
- Attachments via send binding: `content` accepts `ArrayBuffer`/`ArrayBufferView` for binary (PDF) or raw string for text (CSV); total message <= 25 MiB. Note `ArrayBuffer` attachments don't work with `remote:true` local dev — must deploy to test.
- DeepSeek `deepseek-v4-flash` is an external API (not a Cloudflare model); call it over HTTPS from the Worker with the key stored as a Wrangler secret. Both extraction paths (on-device-OCR text, and email-in OCR text) POST to the same internal extractor function for one prompt + one JSON schema.

## 1. Domains, services & bindings overview
Two hostnames, one Worker (or two Workers sharing bindings):

- `snapceipt.app` — apex/marketing + the SENDING identity. All outbound mail is `From: ...@snapceipt.app` (e.g. `no-reply@`, `accounts@`, `exports@`). Onboard via `wrangler email sending enable snapceipt.app`.
- `in.snapceipt.app` — dedicated INBOUND subdomain for email-in receipts. Routing MX points here. Keeping inbound on a subdomain isolates inbound abuse/spam reputation from the sending domain and keeps DMARC alignment clean.

Single Cloudflare Worker `snapceipt-api` exposes:
- HTTP routes: `/auth/magic-link/request`, `/auth/magic-link/verify`, `/auth/apple`, `/extract`, `/sync/push`, `/sync/pull`, `/exports/accountant`, `/r2/sign` (or proxy routes).
- `email()` handler for `in.snapceipt.app` inbound.

wrangler.jsonc bindings:
```jsonc
{
  "name": "snapceipt-api",
  "compatibility_flags": ["nodejs_compat"],
  "send_email": [{ "name": "EMAIL", "allowed_sender_addresses": [
    "no-reply@snapceipt.app", "accounts@snapceipt.app", "exports@snapceipt.app"
  ]}],
  "d1_databases": [{ "binding": "DB", "database_name": "snapceipt", "database_id": "<id>" }],
  "r2_buckets": [{ "binding": "RECEIPTS", "bucket_name": "snapceipt-receipts" }],
  "ai": { "binding": "AI" },
  "kv_namespaces": [{ "binding": "MAGIC_TOKENS", "id": "<id>" }]
}
```
Secrets (via `wrangler secret put`): `DEEPSEEK_API_KEY`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` (only if using presigned URLs), `MAGIC_LINK_HMAC_SECRET`, `APN_AUTH_KEY` / push creds. KV `MAGIC_TOKENS` stores single-use magic-link nonces with TTL; do not store secrets in D1.

## 2. EMAIL SEND — setup
One-time setup (CLI):
```bash
npx wrangler email sending enable snapceipt.app   # adds SPF + DKIM TXT automatically
npx wrangler email sending list                    # confirm domain is active
```
The binding is restricted to the three sender addresses so a bug can never spoof an arbitrary `From`. All sends include both `html` and `text` bodies (deliverability + plain-text clients). Wrap `env.EMAIL.send()` in try/catch and branch on `error.code` (`E_RATE_LIMIT_EXCEEDED`/`E_DELIVERY_FAILED` -> retry w/ backoff; `E_SENDER_NOT_VERIFIED`/`E_VALIDATION_ERROR` -> fix, don't retry; `E_RECIPIENT_SUPPRESSED` -> surface to user, do not retry).

Scope reminder: Email Service is transactional-only. Magic-link + accountant exports qualify. Per the product decision there are NO emailed reminders/budget alerts — those stay in-app (push). Do not add marketing/digest sends to this binding.

## 2a. Template — Magic-link sign-in
Flow: app POSTs `{ email }` to `/auth/magic-link/request`. Worker generates a 32-byte random `nonce`, stores `nonce -> {email, createdAt}` in KV with 600 s TTL (10 min) and single-use semantics, builds a verify URL, and sends:

```ts
const nonce = crypto.randomUUID() + crypto.randomUUID();
await env.MAGIC_TOKENS.put(`ml:${nonce}`, JSON.stringify({ email, ts: Date.now() }), { expirationTtl: 600 });
// Universal Link so it opens the app directly; falls back to web if app absent.
const link = `https://snapceipt.app/auth/verify?token=${nonce}`;
await env.EMAIL.send({
  to: email,
  from: { email: "accounts@snapceipt.app", name: "Snapceipt" },
  subject: "Your Snapceipt sign-in link",
  text: `Tap to sign in to Snapceipt:\n${link}\n\nThis link expires in 10 minutes and can be used once. If you didn’t request it, ignore this email.`,
  html: `<!doctype html><html><body style=\"font-family:-apple-system,Segoe UI,Roboto,sans-serif;background:#f6f7f9;margin:0;padding:24px\">
    <table role=\"presentation\" width=\"100%\" style=\"max-width:480px;margin:auto;background:#fff;border-radius:14px;padding:32px\">
      <tr><td style=\"font-size:20px;font-weight:600;color:#111\">Sign in to Snapceipt</td></tr>
      <tr><td style=\"padding-top:12px;color:#444;font-size:15px;line-height:1.5\">Tap the button below to sign in. This link expires in <b>10 minutes</b> and works once.</td></tr>
      <tr><td style=\"padding:24px 0\"><a href=\"${link}\" style=\"background:#0a7cff;color:#fff;text-decoration:none;padding:12px 22px;border-radius:10px;font-weight:600;display:inline-block\">Sign in</a></td></tr>
      <tr><td style=\"color:#888;font-size:12px\">If the button doesn’t work, paste this URL into your browser:<br>${link}</td></tr>
      <tr><td style=\"color:#aaa;font-size:12px;padding-top:16px\">Didn’t request this? You can safely ignore this email.</td></tr>
    </table></body></html>`
});
```
Verify: `/auth/magic-link/verify?token=` (or app calls the verify endpoint with the token) -> Worker `getWithMetadata` from KV, `delete` immediately (single-use), check TTL not expired, then mint a long-lived session/refresh token bound to the user row in D1 and return it to the app. Sign in with Apple is a parallel path (verify Apple identity token server-side, upsert user by Apple `sub`), reusing the same session-minting code. Security notes: nonce is opaque + single-use + short-TTL; do not embed email in the link; rate-limit requests per-email/IP; the email copy states expiry + one-time use to reduce phishing risk.

## 2b. Template — Send to accountant (PDF + CSV export)
Flow: app POSTs `/exports/accountant` with `{ accountantEmail, dateRange/filter, format: ['pdf','csv'] }` and the user's session. Worker queries D1 for that user's transactions in range, generates the attachments, and emails them. Per decision the user enters the accountant address (no emailed reminders involved).

CSV (raw string content): header tuned for AU bookkeeping —
`Date,Merchant,Category,Subtotal (AUD),GST (AUD),Total (AUD),Tax-Deductible %,Deductible Amount (AUD),Receipt URL`.
GST column = 10% component (Total/11 for GST-inclusive AU receipts); Deductible Amount = Total * deductiblePct. Include a per-export signed R2 URL (7-day expiry) in the last column so the accountant can fetch the original image.

PDF: render a summary statement (totals, GST total, deductible total) + a line table. Generate the PDF bytes in the Worker (e.g. a lightweight pdf-lib build, or pre-render server-side) to an `ArrayBuffer`. NOTE: binary `ArrayBuffer` attachments cannot be tested with `remote:true` local dev — deploy to verify.

```ts
await env.EMAIL.send({
  to: accountantEmail,
  from: { email: "exports@snapceipt.app", name: `${user.displayName} via Snapceipt` },
  replyTo: user.email,                 // accountant replies go to the actual user
  subject: `Snapceipt expenses ${rangeLabel} — ${user.displayName}`,
  text: `Attached: itemised expenses for ${rangeLabel}. CSV for import, PDF summary for review. ${txnCount} transactions, total A$${total}, GST A$${gst}, deductible A$${deductible}.`,
  html: `<p>Hi,</p><p>${user.displayName} shared their Snapceipt expenses for <b>${rangeLabel}</b>.</p>
         <ul><li>${txnCount} transactions</li><li>Total: A$${total}</li><li>GST: A$${gst}</li><li>Tax-deductible: A$${deductible}</li></ul>
         <p>CSV (for accounting software import) and a PDF summary are attached.</p>`,
  attachments: [
    { content: csvString, filename: `snapceipt-${rangeSlug}.csv`, type: "text/csv", disposition: "attachment" },
    { content: pdfArrayBuffer, filename: `snapceipt-${rangeSlug}.pdf`, type: "application/pdf", disposition: "attachment" }
  ]
});
```
Keep total payload < 25 MiB; if a range produces a large PDF or many embedded images, attach CSV + PDF summary only and link images via signed URLs rather than embedding. `replyTo: user.email` keeps the human conversation off the no-reply identity.

## 3. EMAIL ROUTING — email-in receipts
Per-user inbox addressing scheme (uses RFC 5233 subaddressing on `in.snapceipt.app`):
- Each user gets an opaque inbox token `inboxId` (random, ~10 chars, stored on the D1 user row), surfaced in-app as their personal forwarding address: `receipts+<inboxId>@in.snapceipt.app` OR the cleaner `r.<inboxId>@in.snapceipt.app` if using a catch-all on the subdomain.
- Routing config: one catch-all rule on `in.snapceipt.app` -> Worker `email()` handler (catch-all to a Worker is supported). The Worker reads the full localpart from `message.to`, extracts the token, and looks up the user.
- Why opaque token (not the user's real email in the address): the address is sometimes pasted into merchant 'email me my receipt' fields; an opaque token means leaking it only exposes a receipts inbox, not the account. Tokens are revocable/rotatable per user. Always authenticate by `message.from` envelope (trustworthy) + token, and rate-limit per inboxId.

email() handler flow:
```ts
export default {
  async email(message, env, ctx) {
    // 1. Resolve user from the recipient token
    const token = parseInboxToken(message.to); // e.g. 'r.<inboxId>@in.snapceipt.app' or 'receipts+<inboxId>@'
    const user = token ? await lookupUserByInbox(env.DB, token) : null;
    if (!user) { message.setReject("Unknown Snapceipt inbox"); return; }

    // 2. Buffer raw ONCE, parse MIME
    const raw = await new Response(message.raw).arrayBuffer();
    const parsed = await PostalMime.parse(raw);

    // 3. Pick the receipt image attachment (image/* or application/pdf)
    const att = parsed.attachments?.find(a => /^image\//.test(a.mimeType) || a.mimeType === "application/pdf");
    if (!att) { message.setReject("No receipt image attached"); return; }
    const bytes = att.content instanceof ArrayBuffer ? new Uint8Array(att.content) : new Uint8Array(att.content);

    // 4. Store original in R2 (key layout in section 4), generate thumbnail later/async
    const receiptId = crypto.randomUUID();
    const key = `${user.id}/receipts/${receiptId}/original.${ext(att.mimeType)}`;
    await env.RECEIPTS.put(key, bytes, { httpMetadata: { contentType: att.mimeType } });

    // 5. Workers AI OCR (byte-array input)
    const ocr = await env.AI.run("@cf/meta/llama-3.2-11b-vision-instruct", {
      image: [...new Uint8Array(bytes)],
      prompt: "Transcribe ALL text from this receipt exactly as printed, line by line. Output plain text only.",
      max_tokens: 2048,
    });
    const ocrText = ocr.response ?? "";

    // 6. Same extractor as on-device path -> DeepSeek deepseek-v4-flash JSON mode
    const extracted = await runExtractor(env, ocrText); // -> {merchant,date,currencyCode,total,tax,lineItems,...}

    // 7. Create transaction (server-authoritative), bump per-user sync cursor
    await createTransaction(env.DB, user.id, { receiptId, key, source: "email-in", ...extracted });

    // 8. In-app notify (push) — NOT email. Defer heavy work so handler returns fast.
    ctx.waitUntil(sendPush(env, user, { type: "receipt_added", receiptId, merchant: extracted.merchant }));
    ctx.waitUntil(generateThumbnail(env, user.id, receiptId, bytes, att.mimeType));
  }
} satisfies ExportedHandler<Env>;
```
Key design points: handler MUST act (reject/forward/consume) or the mail is dropped; reject on unknown inbox or no image keeps the OCR/AI spend bounded to legitimate mail; the transaction is created server-side and the new row is delivered to the device on the next `/sync/pull` (per-user cursor) — same local-first reconciliation path as on-device scans, last-write-wins on `updatedAt`. Use `isAutoReplyEmail(message.headers)` to skip auto-responders. The shared `runExtractor()` is the single point that calls DeepSeek (one prompt, one JSON schema) for BOTH email-in OCR text and the app's `/extract` (on-device OCR) requests.

## 3a. SPF / DKIM / DMARC
On `wrangler email sending enable snapceipt.app`, Cloudflare auto-publishes SPF (TXT authorizing Cloudflare's senders) and DKIM (selector TXT) for the SENDING domain. You then add DMARC manually.

- SPF (auto, snapceipt.app): `v=spf1 include:_spf.mx.cloudflare.net ~all` (exact include value is provided by onboarding — use what Cloudflare generates, don't hand-author).
- DKIM (auto, snapceipt.app): Cloudflare-managed selector TXT record; signs all outbound. Verify in dashboard that status is Active before first real send.
- DMARC (add manually on snapceipt.app): start monitoring then tighten —
  `_dmarc.snapceipt.app  TXT  "v=DMARC1; p=quarantine; rua=mailto:dmarc@snapceipt.app; adkim=s; aspf=s; pct=100"`
  Begin with `p=none` for 1-2 weeks to confirm alignment via aggregate reports, then move to `p=quarantine` and finally `p=reject`.
- Inbound subdomain `in.snapceipt.app`: enabling Email Routing publishes the required MX records and an SPF TXT for the routing subdomain automatically. Inbound mail is received/parsed regardless of the sender's auth, but you should still read `message.headers` DMARC/SPF/DKIM results and treat failing-auth mail with suspicion (e.g. require a known `message.from` or just rely on the opaque token + per-inbox rate limit). Because sending uses `snapceipt.app` and inbound uses `in.snapceipt.app`, the two reputations are isolated and DMARC alignment for outbound stays strict (`adkim=s; aspf=s`).

## 4. R2 — bucket / key layout, access, lifecycle
Single bucket `snapceipt-receipts`. Key layout (user-scoped, receipt-scoped, deterministic):
```
<userId>/receipts/<receiptId>/original.<jpg|png|pdf>     # full-res scan or email-in attachment
<userId>/receipts/<receiptId>/thumb.jpg                  # ~400px JPEG for list views
<userId>/profile/avatar.jpg                              # optional profile asset
<userId>/exports/<exportId>.pdf                          # generated accountant PDFs (optional retention)
```
User-prefixing every key makes per-user access control and bulk delete (account deletion) a single prefix operation, and keeps listing cheap.

Thumbnails: generate on ingest. For on-device scans the app already has the image — it can upload both `original` and a client-made `thumb` via a presigned PUT, OR upload original only and let the Worker derive the thumbnail. For email-in (no client), derive the thumbnail in the Worker via `ctx.waitUntil(generateThumbnail(...))` using Cloudflare Images transform or a wasm image resize, writing `thumb.jpg` next to the original. Always set `httpMetadata.contentType` on `put`.

Access pattern — choose per use:
- THUMBNAILS + in-app full image: Worker proxy. App calls `GET /r2/<userId>/receipts/<id>/thumb.jpg` with its session token; Worker authorizes (session.userId === path userId), `env.RECEIPTS.get(key)`, streams back with cache headers. Simpler, no key management, and authorization is checked on every request. Recommended default for in-app viewing.
- ACCOUNTANT export links (3rd party, no session): Presigned GET URL via `aws4fetch` with `X-Amz-Expires` set to the export retention window — cap at the R2 max of 7 days (604,800 s); use ~7 days so the accountant has time, then it dies. These are the URLs embedded in the CSV. Presigned URLs need R2 S3 access keys (stored as secrets); the Worker signs them on demand, the URL itself carries no session.
- Direct UPLOAD from app: presigned PUT URL (short expiry, e.g. 300 s) so large images don't transit the Worker, OR Worker-proxied PUT for small files. Presigned PUT keeps the Worker off the upload hot path.
Rule of thumb: session-authenticated in-app traffic -> Worker proxy; unauthenticated external/3rd-party links -> short-lived presigned URL (<= 7 days).

Lifecycle rules (per-bucket):
- `*/exports/*` -> expire/delete 7 days after creation (matches the signed-URL TTL; exports are disposable, regenerable).
- Soft-deleted receipts: app sets a tombstone (soft-delete in D1, source of truth). A scheduled cron Worker purges the matching `<userId>/receipts/<receiptId>/*` objects after a grace period (e.g. 30 days) so undo/cross-device sync works first.
- Optional: transition `original.*` older than N months to R2 Infrequent Access storage class to cut cost if retention is long.
- Account deletion: delete by `<userId>/` prefix (list + batch delete) plus all D1 rows + tombstones.

## 5. Required DNS / domain config
On `snapceipt.app` (SENDING):
- SPF TXT — auto-added by `wrangler email sending enable` (`include:_spf.mx.cloudflare.net`). Don't duplicate; merge if an existing SPF record is present.
- DKIM TXT — auto-added (Cloudflare-managed selector). Confirm Active in dashboard.
- DMARC TXT at `_dmarc.snapceipt.app` — ADD MANUALLY: `v=DMARC1; p=quarantine; rua=mailto:dmarc@snapceipt.app; adkim=s; aspf=s` (ramp from `p=none`).
- Universal Links: serve `/.well-known/apple-app-site-association` from snapceipt.app so the magic-link `https://snapceipt.app/auth/verify` opens the app.

On `in.snapceipt.app` (INBOUND, separate Email Routing zone/subdomain):
- MX records -> Cloudflare Email Routing — auto-published when you enable routing on the subdomain (`route1.mx.cloudflare.net` / `route2` / `route3` style values; use what the dashboard provides).
- SPF TXT for the routing subdomain — auto-published by Email Routing.
- Routing rule: catch-all on `in.snapceipt.app` -> Worker `snapceipt-api` `email()` handler.
- Verify destination addresses only if you also forward (this design ingests in-Worker rather than forwarding, so no verified-destination requirement for the receipt path).

General: both names should be Cloudflare-managed zones (or the subdomain delegated) so Email Routing + Email Service can manage records. Use the exact record values Cloudflare generates during onboarding rather than the illustrative values above.


### Open questions
- Inbox address format preference: `receipts+<token>@in.snapceipt.app` (plain subaddressing, single custom address) vs `r.<token>@in.snapceipt.app` (catch-all, cleaner-looking). Both work; pick based on how the address looks to users when pasted into merchant receipt fields.
- Thumbnail generation owner: client-side (app uploads both original + thumb via presigned PUT) vs Worker-side (Cloudflare Images transform or wasm resize on ingest). Email-in MUST be Worker-side; should the app path match for consistency, or stay client-side to save Worker CPU?
- Should accountant export PDFs be retained in R2 (`<userId>/exports/`) for re-send, or generated ephemerally per request and never stored? Retention adds the 7-day lifecycle rule + signed-link convenience but stores 3rd-party-shareable financial data at rest.
- Magic-link delivery surface: app-only Universal Link, or also a web fallback session for users without the app installed? Affects the verify endpoint and AASA setup.
- Exact DeepSeek endpoint/model id and JSON-mode contract for 'deepseek-v4-flash' (base URL, auth header, schema-enforcement mechanism) — needed to finalize the shared runExtractor() and confirm it matches the on-device /extract response shape the app already expects (merchant, date ISO8601, currencyCode ISO4217, total, tax, lineItems).
- AU tax specifics to confirm for the CSV/PDF: are receipts assumed GST-inclusive (GST = total/11) and is the tax-deductible % per-transaction, per-category, or user-set? This determines the export column math.

### Risks
- Workers AI vision OCR (llama-3.2-11b-vision-instruct) is general-purpose, not a dedicated OCR engine; receipt accuracy may trail specialized OCR. Mitigate by feeding clean attachments and letting DeepSeek normalize; consider Cloudflare's image-to-text alternatives or pre-processing if accuracy is low on the email-in path. On-device Vision OCR (app path) is already strong, so this risk is isolated to email-in receipts.
- DeepSeek 'deepseek-v4-flash' is an external dependency reached over HTTPS from the Worker — adds latency, an API key to rotate, and a third-party availability/cost surface. Worker subrequest timeouts and DeepSeek rate limits must be handled (queue/retry); a failed extraction should still persist the OCR text + image so nothing is lost.
- Cloudflare Email Service was in private/early beta as of late 2025; binding/field names, limits (25 MiB, 50 recipients, daily quota), and onboarding flow can change. Re-verify against live docs before building, and confirm beta access/quota for snapceipt.app.
- Binary ArrayBuffer attachments (the accountant PDF) cannot be exercised with `remote:true` local dev — must deploy to a real environment to validate the PDF/CSV email end-to-end.
- Presigned URL max TTL is 7 days; accountants who sit on an email longer than a week will hit dead image links. The CSV should note the expiry, or provide a re-share action in-app. For long-lived sharing, a tokenized Worker-proxy link (revocable, no fixed TTL) is more robust than a presigned URL.
- Email-in inbox tokens may be pasted into merchant forms and leaked/scraped, inviting spam and OCR/AI cost abuse. Enforce per-inbox rate limits, reject mail with no image, allow token rotation, and optionally pin accepted senders, before relying on the address publicly.
- R2 presigned URLs require S3 access keys stored as Worker secrets — a credential to manage/rotate. The Worker-proxy access pattern avoids this entirely for in-app traffic; only the accountant-link path needs the keys, so scope them tightly.
- Generating PDFs inside a Worker has CPU/memory limits; very large date-range exports could exceed limits or the 25 MiB email cap. Cap rows per PDF, paginate, or move heavy export generation to a Queue/Workflow and email when ready.

---

