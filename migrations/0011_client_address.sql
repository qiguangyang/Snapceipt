-- 0011_client_address.sql — freeform client address on the address book + snapshotted
-- onto the quote at pick time (mirrors clientName/clientEmail). Forward-only. Pure
-- additive ALTER TABLE ADD COLUMN (non-rewriting in SQLite/D1). QUOTES only — invoices
-- intentionally untouched.
--   • clients: address (freeform, multiline, nullable).
--   • quotes:  client_address (snapshot of the picked client's address; nullable).
PRAGMA foreign_keys = OFF;

-- clients — freeform multiline address (optional).
ALTER TABLE clients ADD COLUMN address TEXT;

-- quotes — snapshot of the client's address at pick time (mirrors client_name/email).
ALTER TABLE quotes ADD COLUMN client_address TEXT;
