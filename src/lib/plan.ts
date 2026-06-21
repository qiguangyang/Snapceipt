// src/lib/plan.ts — server-side Pro enforcement. The iOS paywall gates the UI,
// but server-gated Pro actions must independently verify the plan so a modified
// client cannot bypass payment. Reads users.plan (0001) for the authed user.
import type { Context } from "hono";
import type { AppEnv } from "../env";
import { ApiError } from "./errors";
import { nowMs } from "./time";

export async function requireProPlan(c: Context<AppEnv>): Promise<void> {
  const row = await c.env.DB.prepare(
    "SELECT plan, subscription_status, subscription_expires_at FROM users WHERE id = ? AND deleted_at IS NULL",
  )
    .bind(c.var.userId)
    .first<{ plan: string; subscription_status: string | null; subscription_expires_at: number | null }>();
  // Defence in depth: require plan=pro AND a live subscription (not revoked, not past
  // expiry) even if a lifecycle event hasn't flipped `plan` yet. The `expires_at IS NULL`
  // case stays entitled so a pro row without a recorded expiry isn't wrongly denied.
  const now = nowMs();
  const entitled = !!row
    && row.plan === "pro"
    && row.subscription_status !== "revoked"
    && (row.subscription_expires_at == null || row.subscription_expires_at > now);
  if (!entitled) {
    throw new ApiError("FORBIDDEN", "Snapceipt Pro is required for this feature");
  }
}
