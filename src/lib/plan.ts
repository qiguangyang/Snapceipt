// src/lib/plan.ts — server-side Pro enforcement. The iOS paywall gates the UI,
// but server-gated Pro actions must independently verify the plan so a modified
// client cannot bypass payment. Reads users.plan (0001) for the authed user.
import type { Context } from "hono";
import type { AppEnv } from "../env";
import { ApiError } from "./errors";

export async function requireProPlan(c: Context<AppEnv>): Promise<void> {
  const row = await c.env.DB.prepare(
    "SELECT plan FROM users WHERE id = ? AND deleted_at IS NULL",
  ).bind(c.var.userId).first<{ plan: string }>();
  if (!row || row.plan !== "pro") {
    throw new ApiError("FORBIDDEN", "Snapceipt Pro is required for this feature");
  }
}
