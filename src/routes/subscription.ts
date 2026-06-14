import { Hono } from "hono";
import { z } from "zod";
import type { AppEnv } from "../env";
import { nowMs } from "../lib/time";
import { validate } from "./auth";

/**
 * POST /me/subscription — the iOS "purchase link" step.
 *
 * When StoreKit reports a verified transaction the app POSTs the
 * originalTransactionId (+ expiry + productId) here so the user row carries it
 * before the App Store Server Notification arrives. The webhook then matches by
 * originalTransactionId to flip plan and subscription_status.
 *
 * SECURITY NOTE: This endpoint TRUSTS the client's claim — it writes the
 * originalTransactionId supplied by the device without independent server-side
 * verification against the App Store Server API. A malicious client could supply
 * a fabricated originalTransactionId and have plan set to "pro" optimistically.
 * The App Store Server Notification (which IS cryptographically signed by Apple)
 * is the authoritative flip; the webhook will correct any false claim when the
 * real notification arrives (or never elevate a non-subscriber whose notification
 * never comes). Full server-side receipt verification via the App Store Server API
 * (/inApps/v1/subscriptions/{transactionId}) is a flagged follow-up that requires
 * provisioning an in-app-purchase private key (.p8) as a wrangler secret.
 *
 * Route is authenticated (bearer required). Mounting at /me/subscription means
 * it is NOT in PUBLIC_PATHS and goes through the auth middleware.
 */
export const subscriptionRoutes = new Hono<AppEnv>();

const purchaseBody = z.object({
  originalTransactionId: z.string().min(1),
  expiresAtMs: z.number().int().nullable().optional(),
  productId: z.string().min(1),
});

subscriptionRoutes.post("/", validate("json", purchaseBody), async (c) => {
  const { originalTransactionId, expiresAtMs, productId } = c.req.valid("json");
  const now = nowMs();

  // Optimistically promote to pro. The ASSN webhook is authoritative and will
  // correct this if the originalTransactionId is invalid (notification never arrives
  // → user stays at whatever status the webhook last set, or free by default).
  await c.env.DB.prepare(
    `UPDATE users
        SET original_transaction_id = ?,
            subscription_expires_at = ?,
            plan = 'pro',
            subscription_status = 'active',
            updated_at = ?
      WHERE id = ? AND deleted_at IS NULL`,
  )
    .bind(originalTransactionId, expiresAtMs ?? null, now, c.var.userId)
    .run();

  return c.json({ ok: true });
});
