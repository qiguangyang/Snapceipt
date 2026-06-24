-- 0015_client_mobile_phone.sql — mobile phone on the address-book client (mirrors the
-- 0011 address add). Forward-only, pure additive ALTER TABLE ADD COLUMN (non-rewriting in
-- SQLite/D1). Synced via syncTables `client.columns.mobilePhone` ↔ wire key `mobilePhone`.
PRAGMA foreign_keys = OFF;

-- clients — mobile phone (optional).
ALTER TABLE clients ADD COLUMN mobile_phone TEXT;
