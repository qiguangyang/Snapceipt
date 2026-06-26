// src/routes/inbox.ts
import { Hono } from "hono";
import type { AppEnv } from "../env";
import { ApiError } from "../lib/errors";
import { requireProPlan } from "../lib/plan";
import { nowMs } from "../lib/time";
import { addressForToken, mintInboxToken } from "../lib/inboxToken";

/**
 * Per-profile inbox-alias endpoints (auth-gated; rate tier "inbox").
 *  GET  /profiles/:profileId/inbox        — mint-if-absent + return the alias.
 * The GET verifies the profile belongs to c.var.userId (else 404).
 */
export const inboxRoutes = new Hono<AppEnv>();

async function assertOwnedProfile(db: D1Database, userId: string, profileId: string): Promise<void> {
  const owned = await db
    .prepare("SELECT 1 FROM profiles WHERE id = ? AND user_id = ? AND deleted_at IS NULL")
    .bind(profileId, userId)
    .first();
  if (!owned) throw new ApiError("NOT_FOUND", "Profile not found");
}

inboxRoutes.get("/:profileId/inbox", async (c) => {
  const userId = c.var.userId;
  const profileId = c.req.param("profileId");
  await assertOwnedProfile(c.env.DB, userId, profileId);
  await requireProPlan(c); // email-in is Pro-only — after ownership so a non-owner still gets 404.
  const token = await mintInboxToken(c.env.DB, userId, profileId, nowMs());
  return c.json({ profileId, token, address: addressForToken(token) });
});
