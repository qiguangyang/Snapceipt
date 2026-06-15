// App Store Server Notifications V2 — decision layer + verified decode.
// The webhook (src/routes/appstore.ts) VERIFIES the signed payload (Apple JWS
// x5c chain) into a DecodedNotification, then applies the pure reducer below to
// compute the user-row update. The reducer is kept pure (no DB, no crypto) so the
// plan-flip rules are unit-tested in isolation.

import { verifyAppleSignedPayload } from "./appleJws";

/** The fields we need from a decoded ASSN V2 notification + its transaction info. */
export interface DecodedNotification {
  notificationType: string;
  subtype?: string;
  originalTransactionId: string;
  productId: string;
  /** transactionInfo.expiresDate in epoch ms (subscriptions always carry one). */
  expiresDateMs: number | null;
  /** Top-level signedDate from the responseBodyV2DecodedPayload (epoch ms). */
  signedDateMs: number | null;
}

/** The computed user-row update the webhook persists. */
export interface PlanUpdate {
  plan: "free" | "pro";
  subscriptionStatus: "active" | "expired" | "revoked";
  subscriptionExpiresAt: number | null;
}

/**
 * Sentinel returned for no-op notification types (unknown / non-entitlement).
 * The route checks `update === NOOP` and skips the UPDATE statement entirely,
 * preserving the row's last authoritative state.
 */
export const NOOP = Symbol("NOOP");
export type NotificationResult = PlanUpdate | typeof NOOP;

// Notification types that mean the subscriber is (or remains) entitled.
const ENTITLING = new Set([
  "SUBSCRIBED",
  "DID_RENEW",
  "OFFER_REDEEMED",
  "DID_CHANGE_RENEWAL_STATUS", // auto-renew toggled; access persists until expiry
  "DID_CHANGE_RENEWAL_PREF",   // up/downgrade between our tiers; still entitled
]);

// Types that revoke access immediately (money returned / entitlement pulled).
const REVOKING = new Set(["REFUND", "REVOKE"]);

// Types that end access at/after period (lapse).
const EXPIRING = new Set(["EXPIRED", "GRACE_PERIOD_EXPIRED"]);

// Non-entitlement informational types — no plan change needed.
const NOOP_TYPES = new Set([
  "CONSUMPTION_REQUEST",
  "REFUND_DECLINED",
  "PRICE_INCREASE",
  "RENEWAL_EXTENDED",
]);

/**
 * Map a decoded notification to the user-row update, or NOOP when no DB write
 * should occur. Fails CLOSED: unrecognised or non-entitlement types produce NOOP
 * rather than defaulting to pro, so a novel Apple notification type cannot
 * accidentally grant or preserve elevated access.
 *
 * Callers MUST first verify the notification via verifyAppleNotification (which
 * checks Apple's JWS x5c chain against AppleRootCA-G3) — this reducer trusts its
 * input.
 */
export function applyNotification(n: DecodedNotification): NotificationResult {
  if (REVOKING.has(n.notificationType)) {
    return { plan: "free", subscriptionStatus: "revoked", subscriptionExpiresAt: n.expiresDateMs };
  }
  if (EXPIRING.has(n.notificationType)) {
    return { plan: "free", subscriptionStatus: "expired", subscriptionExpiresAt: n.expiresDateMs };
  }
  if (ENTITLING.has(n.notificationType)) {
    return { plan: "pro", subscriptionStatus: "active", subscriptionExpiresAt: n.expiresDateMs };
  }
  // Explicit no-op: informational types that carry no entitlement change.
  // Unknown / future types also fall here — fail CLOSED, preserve existing state.
  return NOOP;
}

interface SignedPayloadData {
  notificationType: string;
  subtype?: string;
  /** epoch ms — top-level timestamp for the responseBodyV2DecodedPayload. */
  signedDate?: number;
  data?: { signedTransactionInfo?: string; signedRenewalInfo?: string };
}
interface TransactionInfo {
  productId: string;
  originalTransactionId: string;
  expiresDate?: number;
}

/** Options forwarded to the JWS verifier (test seam for the trust anchor / clock). */
export interface VerifyNotificationOptions {
  trustAnchorPEM?: string;
  nowMs?: number;
}

/**
 * VERIFY a top-level signedPayload (Apple JWS, x5c chain) and its inner
 * signedTransactionInfo, returning a DecodedNotification. Throws (AppleJwsError
 * or a plain Error) on ANY verification failure or malformed shape — the route
 * treats a throw as a hard rejection (401) and does NOT touch the DB.
 *
 * Both the outer notification envelope AND the inner transaction JWS are signed
 * by Apple with the same x5c chain; we verify each independently so a forged
 * inner transaction (spliced into a genuine envelope) is also rejected.
 */
export async function verifyAppleNotification(
  signedPayload: string,
  opts: VerifyNotificationOptions = {},
): Promise<DecodedNotification> {
  const outer = await verifyAppleSignedPayload<SignedPayloadData>(signedPayload, opts);

  const txnJws = outer.data?.signedTransactionInfo;
  if (!txnJws) throw new Error("notification missing signedTransactionInfo");
  const txn = await verifyAppleSignedPayload<TransactionInfo>(txnJws, opts);

  // signedRenewalInfo, when present, is verified too (defence in depth) even
  // though the reducer does not currently read its fields — a forged renewal
  // blob must not ride along inside an otherwise-genuine notification.
  const renewalJws = outer.data?.signedRenewalInfo;
  if (renewalJws) {
    await verifyAppleSignedPayload<unknown>(renewalJws, opts);
  }

  return {
    notificationType: outer.notificationType,
    subtype: outer.subtype,
    originalTransactionId: txn.originalTransactionId,
    productId: txn.productId,
    expiresDateMs: txn.expiresDate ?? null,
    // signedDate is the top-level epoch-ms timestamp in the V2 responseBody.
    signedDateMs: outer.signedDate ?? null,
  };
}
