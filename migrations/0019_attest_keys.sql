-- App Attest keys: one row per attested Secure-Enclave key (per install).
-- key_id = base64(sha256(pubkey)); device_id is the X-Device-Id at attestation time.
-- No FK to devices (device_id is informational) so account-delete never 500s on ordering;
-- account delete purges these via a device subquery for hygiene.
CREATE TABLE attest_keys (
  key_id       TEXT PRIMARY KEY,
  device_id    TEXT,
  public_key   BLOB NOT NULL,
  sign_count   INTEGER NOT NULL DEFAULT 0,
  aaguid       TEXT,
  created_at   INTEGER NOT NULL,
  last_used_at INTEGER
);
CREATE INDEX ix_attest_keys_device ON attest_keys (device_id);
