-- 0012_subscription_unique_binding.sql — enforce one Apple subscription -> one account.
-- 0006 created a NON-unique index on users(original_transaction_id); replace it with a
-- partial UNIQUE index so a given Apple originalTransactionId can bind to at most one
-- live account. The /me/subscription route also checks ownership before binding (409 on
-- conflict); this is the database backstop. Partial (WHERE NOT NULL) so the many rows
-- with NULL original_transaction_id are unaffected.
DROP INDEX IF EXISTS ix_users_orig_txn;
CREATE UNIQUE INDEX ux_users_orig_txn
  ON users(original_transaction_id)
  WHERE original_transaction_id IS NOT NULL;
