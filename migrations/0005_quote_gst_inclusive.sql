-- 0005_quote_gst_inclusive.sql — GST-inclusive pricing mode for quotes.
-- When 1 (and gst_enabled = 1), the entered line prices already include GST: the
-- grand total stays the entered sum and GST is the embedded 1/11 portion. Default
-- 0 = GST added on top (today's exclusive behaviour) — so existing quotes and
-- older clients that never send the field are unchanged. Pure ADD COLUMN with a
-- constant default (non-rewriting in SQLite/D1); applies via
-- `wrangler d1 migrations apply --remote` and both test harnesses apply it in order.
-- Value is 0/1.
ALTER TABLE quotes ADD COLUMN gst_inclusive INTEGER NOT NULL DEFAULT 0;
