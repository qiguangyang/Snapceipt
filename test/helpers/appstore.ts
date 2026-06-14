/** base64url-encode a JSON value (no padding) — matches JWS segment encoding. */
function b64urlJson(value: unknown): string {
  const json = JSON.stringify(value);
  // btoa is available in the workers test runtime.
  return btoa(json).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** A throwaway JWS: header.payload.signature (signature is a fixed placeholder). */
function jws(payload: unknown): string {
  const header = b64urlJson({ alg: "ES256", x5c: ["TEST"] });
  return `${header}.${b64urlJson(payload)}.SIG`;
}

/**
 * Build a `signedPayload` whose decoded data carries the given notification type,
 * productId, originalTransactionId and expiry — the exact shape our webhook reads.
 */
export function makeSignedNotification(opts: {
  notificationType: string;
  subtype?: string;
  productId?: string;
  originalTransactionId: string;
  expiresDateMs?: number;
}): string {
  const productId = opts.productId ?? "app.snapceipt.pro.monthly";
  const expiresDateMs = opts.expiresDateMs ?? 9_999_999_999_000;
  const signedTransactionInfo = jws({
    productId,
    originalTransactionId: opts.originalTransactionId,
    expiresDate: expiresDateMs,
  });
  const signedRenewalInfo = jws({
    productId,
    originalTransactionId: opts.originalTransactionId,
    autoRenewStatus: 1,
  });
  return jws({
    notificationType: opts.notificationType,
    subtype: opts.subtype,
    data: { signedTransactionInfo, signedRenewalInfo },
  });
}
