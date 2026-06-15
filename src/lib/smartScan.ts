// src/lib/smartScan.ts
// Free/Pro smart-scan cap helpers.
// A "smart scan" = one real LLM (DeepSeek) extraction.
// The cap counts those per user per calendar month (UTC) in smart_scan_usage.
// Server-only; never synced to the client.

/** Default free-tier monthly smart-scan cap. */
export const DEFAULT_CAP_FREE = 10;
/** Default Pro-tier monthly smart-scan cap. */
export const DEFAULT_CAP_PRO = 500;

/**
 * Return the UTC calendar month for `nowMs` as "YYYY-MM".
 * This is the `period` key used in smart_scan_usage.
 */
export function currentPeriod(nowMs: number): string {
  const d = new Date(nowMs);
  const y = d.getUTCFullYear();
  const m = String(d.getUTCMonth() + 1).padStart(2, "0");
  return `${y}-${m}`;
}

/**
 * Return the monthly smart-scan cap for the given plan.
 * Reads SMART_SCAN_CAP_FREE / SMART_SCAN_CAP_PRO from `env` when set as
 * numeric strings (env vars); falls back to DEFAULT_CAP_FREE / DEFAULT_CAP_PRO.
 */
export function capForPlan(
  plan: string | null | undefined,
  env: { SMART_SCAN_CAP_FREE?: string; SMART_SCAN_CAP_PRO?: string },
): number {
  if (plan === "pro") {
    const override = env.SMART_SCAN_CAP_PRO ? Number(env.SMART_SCAN_CAP_PRO) : NaN;
    return Number.isFinite(override) ? override : DEFAULT_CAP_PRO;
  }
  const override = env.SMART_SCAN_CAP_FREE ? Number(env.SMART_SCAN_CAP_FREE) : NaN;
  return Number.isFinite(override) ? override : DEFAULT_CAP_FREE;
}

/**
 * Read the current smart-scan usage count for a user in a period.
 * Returns 0 when no row exists yet.
 */
export async function getUsage(
  db: D1Database,
  userId: string,
  period: string,
): Promise<number> {
  const row = await db
    .prepare("SELECT count FROM smart_scan_usage WHERE user_id = ? AND period = ?")
    .bind(userId, period)
    .first<{ count: number }>();
  return row?.count ?? 0;
}

/**
 * Atomically increment the smart-scan count for a user+period.
 * Uses INSERT ... ON CONFLICT DO UPDATE so it is safe with concurrent requests.
 */
export async function incrementUsage(
  db: D1Database,
  userId: string,
  period: string,
  nowMs: number,
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO smart_scan_usage (user_id, period, count, updated_at)
       VALUES (?, ?, 1, ?)
       ON CONFLICT(user_id, period) DO UPDATE
         SET count = count + 1,
             updated_at = ?`,
    )
    .bind(userId, period, nowMs, nowMs)
    .run();
}

/**
 * Prune smart_scan_usage rows whose period is strictly before `cutoffPeriod`.
 * Call with currentPeriod(now - ~62 days) to keep only the current + last month.
 */
export async function pruneOldUsage(
  db: D1Database,
  cutoffPeriod: string,
): Promise<void> {
  await db
    .prepare("DELETE FROM smart_scan_usage WHERE period < ?")
    .bind(cutoffPeriod)
    .run();
}
