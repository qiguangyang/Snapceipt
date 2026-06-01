import { uuidv7 } from "./ids";
import { nowMs } from "./time";
import { newRefreshToken, hashToken, signAccess, ACCESS_TTL_SECONDS } from "./jwt";

export const REFRESH_TTL_MS = 60 * 24 * 60 * 60 * 1000; // 60-day sliding window

export interface SessionRow {
  id: string;
  user_id: string;
  device_id: string;
  refresh_hash: string;
  family: string;
  created_at: number;
  last_seen_at: number;
  expires_at: number;
  revoked_at: number | null;
}

/**
 * Create a brand-new session family. Mints the HS256 access token, generates an
 * opaque refresh token (stored only as its SHA-256 hash), and inserts the
 * sessions row. The plaintext refresh token is returned exactly once.
 *
 * Per the Canonical Contracts, issueSession owns access-token minting and needs
 * `c.env.JWT_SIGNING_KEY`, so callers pass the env-derived signing key.
 */
export async function issueSession(
  db: D1Database,
  args: { userId: string; deviceId: string; signingKey: string },
): Promise<{
  accessToken: string;
  refreshToken: string;
  expiresIn: number;
  sessionId: string;
  family: string;
}> {
  const id = uuidv7();
  const family = uuidv7();
  const refreshToken = newRefreshToken();
  const refreshHash = await hashToken(refreshToken);
  const t = nowMs();

  await db
    .prepare(
      `INSERT INTO sessions
         (id, user_id, device_id, refresh_hash, family, created_at, last_seen_at, expires_at, revoked_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL)`,
    )
    .bind(id, args.userId, args.deviceId, refreshHash, family, t, t, t + REFRESH_TTL_MS)
    .run();

  const accessToken = await signAccess(args.signingKey, {
    userId: args.userId,
    sessionId: id,
    deviceId: args.deviceId,
  });

  return {
    accessToken,
    refreshToken,
    expiresIn: ACCESS_TTL_SECONDS,
    sessionId: id,
    family,
  };
}

/** Find a live (not revoked, not expired) session by the sha256 hash of its current refresh token. */
export async function findSessionByRefreshHash(
  db: D1Database,
  refreshHash: string,
): Promise<SessionRow | null> {
  const row = await db
    .prepare(
      `SELECT * FROM sessions
        WHERE refresh_hash = ? AND revoked_at IS NULL AND expires_at > ?`,
    )
    .bind(refreshHash, nowMs())
    .first<SessionRow>();
  return row ?? null;
}

/**
 * Rotate the refresh token in place: install a new hash, slide the 60-day expiry,
 * keep the same session id + family. Returns the new plaintext refresh token.
 *
 * The UPDATE is guarded with `revoked_at IS NULL`, so a missing/already-revoked
 * session writes zero rows. We RETURNING the family from the same statement and
 * throw a meaningful error if nothing came back, instead of dereferencing a
 * non-null assertion on an absent row.
 */
export async function rotateSession(
  db: D1Database,
  sessionId: string,
): Promise<{ sessionId: string; refreshToken: string; family: string }> {
  const refreshToken = newRefreshToken();
  const refreshHash = await hashToken(refreshToken);
  const t = nowMs();

  const row = await db
    .prepare(
      `UPDATE sessions
          SET refresh_hash = ?, last_seen_at = ?, expires_at = ?
        WHERE id = ? AND revoked_at IS NULL
        RETURNING family`,
    )
    .bind(refreshHash, t, t + REFRESH_TTL_MS, sessionId)
    .first<{ family: string }>();

  if (!row) {
    throw new Error(`rotateSession: no live session to rotate for id=${sessionId}`);
  }

  return { sessionId, refreshToken, family: row.family };
}

/** Revoke a single session (sign-out of one device). */
export async function revokeSession(db: D1Database, sessionId: string): Promise<void> {
  await db
    .prepare("UPDATE sessions SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL")
    .bind(nowMs(), sessionId)
    .run();
}

/** Revoke every session in a family — used on refresh-token reuse detection. */
export async function revokeSessionFamily(db: D1Database, family: string): Promise<void> {
  await db
    .prepare("UPDATE sessions SET revoked_at = ? WHERE family = ? AND revoked_at IS NULL")
    .bind(nowMs(), family)
    .run();
}
