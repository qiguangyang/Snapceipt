import { env } from "cloudflare:test";

/**
 * Insert a live `sessions` row so a `signAccess`-minted token passes the S4
 * session-liveness check (`isSessionLive`) on gated routes (account delete, sync push).
 * Mirrors what `issueSession` would create. `INSERT OR REPLACE` keeps it idempotent
 * across `beforeEach` re-runs. The owning user must already exist (FK).
 */
export async function seedSession(opts: {
  id: string;
  userId: string;
  deviceId: string;
  now?: number;
  revoked?: boolean;
}): Promise<void> {
  const now = opts.now ?? Date.now();
  await env.DB.prepare(
    `INSERT OR REPLACE INTO sessions
       (id, user_id, device_id, family, refresh_hash, created_at, last_seen_at, expires_at, revoked_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  )
    .bind(
      opts.id, opts.userId, opts.deviceId,
      `fam-${opts.id}`, `rh-${opts.id}`,
      now, now, now + 3_600_000,
      opts.revoked ? now : null,
    )
    .run();
}
