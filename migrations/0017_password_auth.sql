-- Password authentication + per-device trust (2FA on new devices).
--
-- password_hash: PBKDF2 string ("pbkdf2$<iterations>$<saltB64>$<hashB64>"); NULL = the user
--   has no password yet (existing users + accounts created via code only). Optional — code
--   login still works without one.
-- trusted_at: epoch ms a device was verified via a 6-digit code (or set its first password).
--   A password login from a device with NULL trusted_at is challenged with a code (MFA), then
--   the device is trusted.
ALTER TABLE users ADD COLUMN password_hash TEXT;
ALTER TABLE devices ADD COLUMN trusted_at INTEGER;
