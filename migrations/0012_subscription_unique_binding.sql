-- 0012_subscription_unique_binding.sql — enforce one Apple subscription -> one account.
-- 0006 created a NON-unique index on users(original_transaction_id); replace it with a
-- partial UNIQUE index so a given Apple originalTransactionId can bind to at most one
-- live account. The /me/subscription route also checks ownership before binding (409 on
-- conflict); this is the database backstop.
--
-- DEDUP FIRST: the pre-fix route bound original_transaction_id unconditionally, and Pro
-- has been live in TestFlight, so prod may already hold duplicate bindings (Family
-- Sharing / shared Apple ID / cross-account restore). CREATE UNIQUE INDEX is evaluated
-- against existing rows and would abort the whole `migrations apply --remote` on a
-- violation. So first release all-but-the-most-recent row per duplicate group (NULL the
-- id + mark free/revoked); the genuine current subscriber — the most recent lifecycle
-- event — keeps the binding. On a fresh/clean DB this UPDATE matches zero rows (no-op).
UPDATE users
   SET original_transaction_id = NULL,
       plan = 'free',
       subscription_status = 'revoked'
 WHERE id IN (
   SELECT id FROM (
     SELECT id,
            ROW_NUMBER() OVER (
              PARTITION BY original_transaction_id
              ORDER BY subscription_last_event_at DESC, updated_at DESC
            ) AS rn
       FROM users
      WHERE original_transaction_id IS NOT NULL
   )
   WHERE rn > 1
 );

DROP INDEX IF EXISTS ix_users_orig_txn;
CREATE UNIQUE INDEX ux_users_orig_txn
  ON users(original_transaction_id)
  WHERE original_transaction_id IS NOT NULL;
