-- 0006_subscriptions.sql — Apple StoreKit subscription tracking on users.
-- `plan` already exists (0001, CHECK IN ('free','pro')); these columns record the
-- subscription lifecycle so the App Store Server Notifications webhook can flip
-- plan and reconcile renewals/expiry. Pure ADD COLUMN with constant defaults
-- (non-rewriting in SQLite/D1); applies via `wrangler d1 migrations apply --remote`
-- and both test harnesses apply it in order. No CHECK changes on `plan`.
ALTER TABLE users ADD COLUMN subscription_status TEXT;            -- 'active'|'expired'|'revoked'|NULL
ALTER TABLE users ADD COLUMN subscription_expires_at INTEGER;     -- epoch ms; NULL when never subscribed
ALTER TABLE users ADD COLUMN original_transaction_id TEXT;        -- Apple originalTransactionId (stable per subscriber)
CREATE INDEX ix_users_orig_txn ON users(original_transaction_id) WHERE original_transaction_id IS NOT NULL;
