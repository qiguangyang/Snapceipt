-- 0010_quote_tax_business.sql — configurable GST rate + business-profile details
-- + logo R2 key (spec §3, §5, §7). Forward-only. Pure additive ALTER TABLE ADD
-- COLUMN (non-rewriting in SQLite/D1).
--   • profiles: gst_rate_bp (default 1000 = 10%), business_email, phone, website,
--     address, bank_details, logo_r2_key (logo_r2_key is server-owned).
--   • quotes / invoices: gst_rate_bp (nullable; null ⇒ treated as 1000 = 10% by the
--     totals engine + the "GST (X%)" label, so pre-feature documents keep 10%).
-- Money = INTEGER cents. Timestamps = INTEGER epoch ms. Dates = TEXT 'YYYY-MM-DD'.
PRAGMA foreign_keys = OFF;

-- profiles — GST rate (basis points) + business details + logo key.
ALTER TABLE profiles ADD COLUMN gst_rate_bp   INTEGER DEFAULT 1000;
ALTER TABLE profiles ADD COLUMN business_email TEXT;
ALTER TABLE profiles ADD COLUMN phone          TEXT;
ALTER TABLE profiles ADD COLUMN website        TEXT;
ALTER TABLE profiles ADD COLUMN address        TEXT;
ALTER TABLE profiles ADD COLUMN bank_details   TEXT;
ALTER TABLE profiles ADD COLUMN logo_r2_key    TEXT;

-- quotes / invoices — snapshotted GST rate (nullable; null ⇒ 1000).
ALTER TABLE quotes   ADD COLUMN gst_rate_bp INTEGER;
ALTER TABLE invoices ADD COLUMN gst_rate_bp INTEGER;
