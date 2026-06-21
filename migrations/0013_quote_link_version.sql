-- 0013_quote_link_version.sql — revocable public quote links.
-- The public /q/:token page renders the quote live from current DB state (incl. business
-- bank details + client PII) and the signed link is long-lived, with no way to revoke a
-- leaked link short of rotating the global JWT key. Add a per-quote version counter: the
-- link token carries the version it was minted at, and the public route serves the quote
-- only when the token version matches the quote's current link_version. Bumping
-- link_version (POST /quotes/:id/link/revoke) invalidates every previously-minted link.
-- Pure ADD COLUMN with a constant default (non-rewriting in SQLite/D1). Existing links
-- carry no version claim → treated as version 0 → still valid until an explicit revoke.
ALTER TABLE quotes ADD COLUMN link_version INTEGER NOT NULL DEFAULT 0;
