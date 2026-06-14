// App Store Server Notifications V2 — pure decision layer.
// The webhook (src/routes/appstore.ts) decodes the signed payload into a
// DecodedNotification, then applies this reducer to compute the user-row update.
// Kept pure (no DB, no crypto) so the plan-flip rules are unit-tested in isolation.

/** The fields we need from a decoded ASSN V2 notification + its transaction info. */
export interface DecodedNotification {
  notificationType: string;
  subtype?: string;
  originalTransactionId: string;
  productId: string;
  /** transactionInfo.expiresDate in epoch ms (subscriptions always carry one). */
  expiresDateMs: number | null;
}

/** The computed user-row update the webhook persists. */
export interface PlanUpdate {
  plan: "free" | "pro";
  subscriptionStatus: "active" | "expired" | "revoked";
  subscriptionExpiresAt: number | null;
}

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

/**
 * Map a decoded notification to the user-row update. Unrecognised types default to
 * entitled+active so a new Apple notification type never spuriously downgrades a
 * paying user (unknown types should not reach prod, but we fail OPEN for the payer).
 */
export function applyNotification(n: DecodedNotification): PlanUpdate {
  if (REVOKING.has(n.notificationType)) {
    return { plan: "free", subscriptionStatus: "revoked", subscriptionExpiresAt: n.expiresDateMs };
  }
  if (EXPIRING.has(n.notificationType)) {
    return { plan: "free", subscriptionStatus: "expired", subscriptionExpiresAt: n.expiresDateMs };
  }
  if (ENTITLING.has(n.notificationType)) {
    return { plan: "pro", subscriptionStatus: "active", subscriptionExpiresAt: n.expiresDateMs };
  }
  // Conservative default for unrecognised types: keep the subscriber entitled.
  return { plan: "pro", subscriptionStatus: "active", subscriptionExpiresAt: n.expiresDateMs };
}

/** Decode a JWS payload segment (base64url JSON). GA: we decode, not chain-verify
 *  (TLS transport from Apple is trusted; x5c pinning is a flagged follow-up). */
function decodeJwsPayload<T>(jwsToken: string): T {
  const part = jwsToken.split(".")[1];
  if (!part) throw new Error("malformed JWS");
  const b64 = part.replace(/-/g, "+").replace(/_/g, "/");
  const json = atob(b64.padEnd(b64.length + ((4 - (b64.length % 4)) % 4), "="));
  return JSON.parse(json) as T;
}

interface SignedPayloadData {
  notificationType: string;
  subtype?: string;
  data?: { signedTransactionInfo?: string; signedRenewalInfo?: string };
}
interface TransactionInfo {
  productId: string;
  originalTransactionId: string;
  expiresDate?: number;
}

/** Decode a top-level signedPayload into our DecodedNotification, or null if malformed. */
export function decodeSignedPayload(signedPayload: string): DecodedNotification | null {
  let outer: SignedPayloadData;
  try {
    outer = decodeJwsPayload<SignedPayloadData>(signedPayload);
  } catch {
    return null;
  }
  const txnJws = outer.data?.signedTransactionInfo;
  if (!txnJws) return null;
  let txn: TransactionInfo;
  try {
    txn = decodeJwsPayload<TransactionInfo>(txnJws);
  } catch {
    return null;
  }
  return {
    notificationType: outer.notificationType,
    subtype: outer.subtype,
    originalTransactionId: txn.originalTransactionId,
    productId: txn.productId,
    expiresDateMs: txn.expiresDate ?? null,
  };
}
