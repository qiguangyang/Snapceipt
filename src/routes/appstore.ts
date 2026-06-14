import { Hono } from "hono";
import { z } from "zod";
import type { AppEnv } from "../env";
import { nowMs } from "../lib/time";
import { validate } from "./auth";
import { applyNotification, decodeSignedPayload } from "../lib/appStoreNotifications";

/**
 * App Store Server Notifications V2 webhook. Public (Apple posts unauthenticated),
 * mounted under /appstore which is added to PUBLIC_PATHS. Body is { signedPayload }
 * (a JWS). We decode it, compute the plan update via applyNotification, and flip the
 * user row keyed by originalTransactionId. ALWAYS 200 on a well-formed body (even
 * when no user matches) so Apple does not retry indefinitely; only a malformed body
 * (missing signedPayload) is 400.
 *
 * Security posture: GA decodes but does NOT verify the JWS x5c cert chain. TLS
 * transport from Apple's documented IP ranges is trusted at the network layer.
 * Full x5c-chain pinning (Apple's AppleRootCA-G3) is a flagged follow-up in the
 * plan's open_questions. Forged notifications from a non-Apple source require network
 * access to reach the Worker (TLS + Cloudflare edge filtering), and the worst-case
 * from a forged SUBSCRIBED is a free user being upgraded to pro — the inverse (a
 * forged REVOKE downgrades a real subscriber) is a bigger risk; x5c pinning closes
 * that for GA+1.
 */
export const appstoreRoutes = new Hono<AppEnv>();

const notificationBody = z.object({ signedPayload: z.string().min(1) });

appstoreRoutes.post("/notifications", validate("json", notificationBody), async (c) => {
  const { signedPayload } = c.req.valid("json");

  const decoded = decodeSignedPayload(signedPayload);
  if (!decoded) {
    // Well-formed envelope but undecodable inner JWS — ack so Apple stops retrying.
    return c.json({ ok: true, ignored: "undecodable" });
  }

  const update = applyNotification(decoded);
  const now = nowMs();

  // Scope by Apple's stable originalTransactionId (tagged on the user row at first
  // purchase / link). No match -> no-op (still 200) so Apple does not retry.
  await c.env.DB.prepare(
    `UPDATE users
        SET plan = ?,
            subscription_status = ?,
            subscription_expires_at = ?,
            updated_at = ?
      WHERE original_transaction_id = ? AND deleted_at IS NULL`,
  )
    .bind(update.plan, update.subscriptionStatus, update.subscriptionExpiresAt, now, decoded.originalTransactionId)
    .run();

  return c.json({ ok: true });
});
