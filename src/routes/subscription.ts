import { Hono } from "hono";
import { z } from "zod";
import type { AppEnv } from "../env";
import { nowMs } from "../lib/time";
import { validate } from "./auth";
import { AppleJwsError, verifyAppleSignedPayload } from "../lib/appleJws";

/**
 * POST /me/subscription — the iOS "purchase link" step.
 *
 * The app POSTs the StoreKit 2 SIGNED transaction (`signedTransaction`, i.e. the
 * transaction's `jwsRepresentation`). The server VERIFIES Apple's JWS x5c chain
 * (AppleRootCA-G3), then asserts the verified payload's bundleId matches our app
 * and its productId is one of our Pro subscriptions. The originalTransactionId and
 * expiry are taken FROM THE VERIFIED PAYLOAD — never from client-asserted fields —
 * before the user row is flipped to pro.
 *
 * SECURITY: a forged / tampered / wrong-bundle / wrong-product transaction is
 * rejected (401/400) and the plan is NOT changed. The App Store Server
 * Notification (also verified) remains the authoritative source for later
 * lifecycle events (renewal / refund / expiry).
 *
 * Route is authenticated (bearer required). Mounting at /me/subscription means it
 * is NOT in PUBLIC_PATHS and goes through the auth middleware.
 */
export const subscriptionRoutes = new Hono<AppEnv>();

/** Our two entitling Pro subscription product ids (Snapceipt/Snapceipt.storekit). */
const PRO_PRODUCT_IDS = new Set(["app.snapceipt.pro.monthly", "app.snapceipt.pro.yearly"]);

const purchaseBody = z.object({
  // The StoreKit 2 signed transaction JWS (Transaction.jwsRepresentation).
  signedTransaction: z.string().min(1).max(32_768),
});

/** The fields we read out of a verified StoreKit JWSTransactionDecodedPayload. */
interface VerifiedTransaction {
  bundleId?: string;
  productId?: string;
  originalTransactionId?: string;
  /** expiresDate is epoch ms for auto-renewable subscriptions. */
  expiresDate?: number;
}

subscriptionRoutes.post("/", validate("json", purchaseBody), async (c) => {
  const { signedTransaction } = c.req.valid("json");

  // 1. VERIFY Apple's signature + x5c chain before trusting anything in the JWS.
  let txn: VerifiedTransaction;
  try {
    txn = await verifyAppleSignedPayload<VerifiedTransaction>(signedTransaction, {
      trustAnchorPEM: c.env.APPLE_TRUST_ANCHOR_PEM,
    });
  } catch (err) {
    const reason = err instanceof AppleJwsError ? err.message : "unverifiable transaction";
    return c.json({ ok: false, error: "SIGNATURE_INVALID", reason }, 401);
  }

  // 2. The transaction must be for OUR app and one of our Pro products. These come
  //    from the verified payload, so a client cannot spoof them.
  if (txn.bundleId !== c.env.APPLE_BUNDLE_ID) {
    return c.json({ ok: false, error: "BUNDLE_MISMATCH" }, 400);
  }
  if (!txn.productId || !PRO_PRODUCT_IDS.has(txn.productId)) {
    return c.json({ ok: false, error: "PRODUCT_NOT_PRO" }, 400);
  }
  if (!txn.originalTransactionId) {
    return c.json({ ok: false, error: "MISSING_ORIGINAL_TRANSACTION_ID" }, 400);
  }

  // 3. Derive the linkage fields FROM THE VERIFIED PAYLOAD and flip to pro.
  const originalTransactionId = txn.originalTransactionId;
  const expiresAtMs = typeof txn.expiresDate === "number" ? txn.expiresDate : null;
  const now = nowMs();

  await c.env.DB.prepare(
    `UPDATE users
        SET original_transaction_id = ?,
            subscription_expires_at = ?,
            plan = 'pro',
            subscription_status = 'active',
            updated_at = ?
      WHERE id = ? AND deleted_at IS NULL`,
  )
    .bind(originalTransactionId, expiresAtMs, now, c.var.userId)
    .run();

  return c.json({ ok: true });
});
