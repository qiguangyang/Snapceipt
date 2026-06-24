// src/lib/plan.ts — server-side Pro enforcement. The iOS paywall gates the UI,
// but server-gated Pro actions must independently verify the plan so a modified
// client cannot bypass payment. Reads users.plan (0001) for the authed user.
import type { Context } from "hono";
import type { AppEnv } from "../env";
import { ApiError } from "./errors";
import { nowMs } from "./time";

// userId/db-based Pro check, usable outside a Hono Context (e.g. the email inbound
// handler). Defence in depth: require plan=pro AND a live subscription (not revoked,
// not past expiry) even if a lifecycle event hasn't flipped `plan` yet. The
// `expires_at IS NULL` case stays entitled so a pro row without a recorded expiry
// isn't wrongly denied.
export async function isProUser(db: D1Database, userId: string): Promise<boolean> {
  const row = await db.prepare(
    "SELECT plan, subscription_status, subscription_expires_at FROM users WHERE id = ? AND deleted_at IS NULL",
  )
    .bind(userId)
    .first<{ plan: string; subscription_status: string | null; subscription_expires_at: number | null }>();
  const now = nowMs();
  return !!row
    && row.plan === "pro"
    && row.subscription_status !== "revoked"
    && (row.subscription_expires_at == null || row.subscription_expires_at > now);
}

export async function requireProPlan(c: Context<AppEnv>): Promise<void> {
  if (!(await isProUser(c.env.DB, c.var.userId))) {
    throw new ApiError("FORBIDDEN", "Snapceipt Pro is required for this feature");
  }
}
