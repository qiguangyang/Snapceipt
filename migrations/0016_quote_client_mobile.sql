-- 0016_quote_client_mobile.sql — snapshot of the picked client's mobile phone onto the quote
-- at pick time (mirrors 0011's quotes.client_address). Forward-only, pure additive
-- ALTER TABLE ADD COLUMN (non-rewriting in SQLite/D1). Rendered in the To block of the
-- hosted quote page. QUOTES only — invoices intentionally untouched.
PRAGMA foreign_keys = OFF;

-- quotes — snapshot of the client's mobile at pick time (mirrors client_address).
ALTER TABLE quotes ADD COLUMN client_mobile TEXT;
