import { Hono } from "hono";
import { z } from "zod";
import type { AppEnv } from "../env";
import { nowMs } from "../lib/time";
import { validate } from "./auth";
import { applyNotification, decodeSignedPayload, NOOP } from "../lib/appStoreNotifications";

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

// 16 KiB ceiling — a JWS with a real x5c cert chain is well under this; anything
// larger is almost certainly malformed or an abuse attempt.
const MAX_SIGNED_PAYLOAD_BYTES = 16_384;

const notificationBody = z.object({
  signedPayload: z.string().min(1).max(MAX_SIGNED_PAYLOAD_BYTES),
});

appstoreRoutes.post("/notifications", validate("json", notificationBody), async (c) => {
  const { signedPayload } = c.req.valid("json");

  const decoded = decodeSignedPayload(signedPayload);
  if (!decoded) {
    // Well-formed envelope but undecodable inner JWS — ack so Apple stops retrying.
    return c.json({ ok: true, ignored: "undecodable" });
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
