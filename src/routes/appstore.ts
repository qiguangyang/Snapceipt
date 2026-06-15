import { Hono } from "hono";
import { z } from "zod";
import type { AppEnv } from "../env";
import { nowMs } from "../lib/time";
import { validate } from "./auth";
import { applyNotification, verifyAppleNotification, NOOP } from "../lib/appStoreNotifications";
import { AppleJwsError } from "../lib/appleJws";

/**
 * App Store Server Notifications V2 webhook. Public (Apple posts unauthenticated),
 * mounted under /appstore which is added to PUBLIC_PATHS. Body is { signedPayload }
 * (a JWS). We VERIFY Apple's x5c cert chain (AppleRootCA-G3) on the outer payload
 * AND the inner signedTransactionInfo, compute the plan update via applyNotification,
 * and flip the user row keyed by originalTransactionId.
 *
 * Security posture: a notification whose JWS signature / cert chain / trust anchor
 * does NOT verify is rejected with 401 and the DB is never touched — a forged or
 * tampered notification (e.g. a spoofed REVOKE downgrading a real subscriber, or a
 * forged SUBSCRIBED upgrading a non-payer) cannot move plan state. On a VERIFIED
 * payload we still ALWAYS 200 (even when no user matches) so Apple does not retry
 * indefinitely.
 */
export const appstoreRoutes = new Hono<AppEnv>();

// 32 KiB ceiling. A real V2 notification nests THREE Apple JWS (outer envelope +
// inner signedTransactionInfo + signedRenewalInfo), each carrying a full x5c cert
// chain, so the verified envelope runs noticeably larger than a bare token; 32 KiB
// comfortably fits a genuine Apple payload while still rejecting abusive bodies.
const MAX_SIGNED_PAYLOAD_BYTES = 32_768;

const notificationBody = z.object({
  signedPayload: z.string().min(1).max(MAX_SIGNED_PAYLOAD_BYTES),
});

appstoreRoutes.post("/notifications", validate("json", notificationBody), async (c) => {
  const { signedPayload } = c.req.valid("json");

  // VERIFY Apple's JWS x5c chain (outer notification + inner transaction) before
  // trusting anything. Any failure → 401 and NO DB write. The trust anchor is the
  // real AppleRootCA-G3 by default; tests inject their own via APPLE_TRUST_ANCHOR_PEM.
  let decoded;
  try {
    decoded = await verifyAppleNotification(signedPayload, {
      trustAnchorPEM: c.env.APPLE_TRUST_ANCHOR_PEM,
    });
  } catch (err) {
    const reason = err instanceof AppleJwsError ? err.message : "unverifiable notification";
    return c.json({ ok: false, error: "SIGNATURE_INVALID", reason }, 401);
  }

  // Fix 4: reject notifications with no/empty originalTransactionId — these cannot
  // be scoped to a user row and indicate a malformed or forged payload.
  if (!decoded.originalTransactionId) {
    return c.json({ ok: false, error: "VALIDATION_FAILED" }, 400);
  }

  const update = applyNotification(decoded);

  // Fix 1: NOOP sentinel means the notification type carries no entitlement change
  // (unknown / informational types). Preserve the row's last authoritative state.
  if (update === NOOP) {
    return c.json({ ok: true, ignored: "noop" });
  }

  const now = nowMs();
  // signedDate is the top-level epoch-ms timestamp from the V2 responseBodyV2
  // payload. Use it as the event time for the monotonic replay guard; fall back
  // to now if the field is absent (should not happen for well-formed Apple payloads).
  const eventAt = decoded.signedDateMs ?? now;

  // Fix 2: monotonic guard — only apply if the incoming event is at least as new
  // as the last applied event. A replayed stale notification (e.g. an EXPIRED that
  // arrives after a DID_RENEW was processed) is silently no-oped.
  // Scope by Apple's stable originalTransactionId (tagged on the user row at first
  // purchase / link). No match -> no-op (still 200) so Apple does not retry.
  await c.env.DB.prepare(
    `UPDATE users
        SET plan = ?,
            subscription_status = ?,
            subscription_expires_at = ?,
            subscription_last_event_at = ?,
            updated_at = ?
      WHERE original_transaction_id = ?
        AND deleted_at IS NULL
        AND (subscription_last_event_at IS NULL OR ? >= subscription_last_event_at)`,
  )
    .bind(
      update.plan,
      update.subscriptionStatus,
      update.subscriptionExpiresAt,
      eventAt,
      now,
      decoded.originalTransactionId,
      eventAt,
    )
    .run();

  return c.json({ ok: true });
});
