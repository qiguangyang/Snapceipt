import { SignJWT, jwtVerify } from "jose";

/**
 * Signed download token for the PUBLIC GET /export/dl/:token route. It carries a
 * single custom claim `rk` (the R2 object key) plus the standard `exp`, signed
 * HS256 with the same JWT_SIGNING_KEY as the access token but under a DISTINCT
 * issuer/audience so an access token can never be replayed as a download token
 * (and vice versa). jose enforces signature + expiry on verify.
 */

export const DOWNLOAD_TTL_SECONDS = 7 * 24 * 60 * 60; // 7 days
const ISSUER = "snapceipt-export";
const AUDIENCE = "snapceipt-export-dl";

function keyBytes(signingKey: string): Uint8Array {
  return new TextEncoder().encode(signingKey);
}

/** Sign a download token for an R2 key. `ttlSeconds` defaults to 7 days; a
 *  negative value lets tests mint an already-expired token. */
export async function signDownloadToken(
  signingKey: string,
  r2Key: string,
  ttlSeconds: number = DOWNLOAD_TTL_SECONDS,
): Promise<string> {
  return new SignJWT({ rk: r2Key })
    .setProtectedHeader({ alg: "HS256", typ: "JWT" })
    .setIssuer(ISSUER)
    .setAudience(AUDIENCE)
    .setIssuedAt()
    .setExpirationTime(`${ttlSeconds}s`)
    .sign(keyBytes(signingKey));
}

/** Verify a download token. Throws (jose JWTExpired / signature / claim error)
 *  on any failure — the route maps a throw to 403. */
export async function verifyDownloadToken(
  signingKey: string,
  token: string,
): Promise<{ r2Key: string }> {
  const { payload } = await jwtVerify(token, keyBytes(signingKey), {
    issuer: ISSUER,
    audience: AUDIENCE,
    algorithms: ["HS256"],
  });
  const rk = (payload as { rk?: unknown }).rk;
  if (typeof rk !== "string" || rk.length === 0) {
    throw new Error("download token missing rk claim");
  }
  return { r2Key: rk };
}

/**
 * Signed token for the PUBLIC GET /q/:token HTML-quote page. Carries `qid` (quote id)
 * + `uid` (owning user id) so the route can load + tenant-scope the quote without an
 * access token. Long-lived (30 days) — a client may open the link days later. Signed
 * HS256 with the same JWT_SIGNING_KEY but a DISTINCT issuer/audience from both the
 * access token and the download token, so no token can be replayed across surfaces.
 */
export const QUOTE_LINK_TTL_SECONDS = 30 * 24 * 60 * 60; // 30 days
const QUOTE_LINK_ISSUER = "snapceipt-quote";
const QUOTE_LINK_AUDIENCE = "snapceipt-quote-link";

/** Sign a quote-link token. Carries `v` = the quote's link_version at mint time so the
 *  public route can reject links from before a revoke/re-issue. `ttlSeconds` defaults to
 *  30 days; a negative value lets tests mint an already-expired token. */
export async function signQuoteLinkToken(
  signingKey: string,
  quoteId: string,
  userId: string,
  linkVersion: number = 0,
  ttlSeconds: number = QUOTE_LINK_TTL_SECONDS,
): Promise<string> {
  return new SignJWT({ qid: quoteId, uid: userId, v: linkVersion })
    .setProtectedHeader({ alg: "HS256", typ: "JWT" })
    .setIssuer(QUOTE_LINK_ISSUER)
    .setAudience(QUOTE_LINK_AUDIENCE)
    .setIssuedAt()
    .setExpirationTime(`${ttlSeconds}s`)
    .sign(keyBytes(signingKey));
}

/** Verify a quote-link token. Throws (jose JWTExpired / signature / claim error) on
 *  any failure — the route maps a throw to 403. `version` defaults to 0 for legacy tokens
 *  minted before the `v` claim existed (those stay valid until an explicit revoke bumps
 *  the quote past version 0). */
export async function verifyQuoteLinkToken(
  signingKey: string,
  token: string,
): Promise<{ quoteId: string; userId: string; version: number }> {
  const { payload } = await jwtVerify(token, keyBytes(signingKey), {
    issuer: QUOTE_LINK_ISSUER,
    audience: QUOTE_LINK_AUDIENCE,
    algorithms: ["HS256"],
  });
  const qid = (payload as { qid?: unknown }).qid;
  const uid = (payload as { uid?: unknown }).uid;
  const v = (payload as { v?: unknown }).v;
  if (typeof qid !== "string" || qid.length === 0 || typeof uid !== "string" || uid.length === 0) {
    throw new Error("quote-link token missing qid/uid claim");
  }
  return { quoteId: qid, userId: uid, version: typeof v === "number" ? v : 0 };
}

/**
 * Signed token for the PUBLIC GET /i/:token HTML tax-invoice page. Carries `iid` (invoice id)
 * + `uid` (owning user id) so the route can load + tenant-scope the invoice without an access
 * token. Long-lived (30 days) — a client may open the link days later. Signed HS256 with the
 * same JWT_SIGNING_KEY but a DISTINCT issuer/audience from the access, download, AND quote-link
 * tokens, so no token can be replayed across surfaces.
 */
export const INVOICE_LINK_TTL_SECONDS = 30 * 24 * 60 * 60; // 30 days
const INVOICE_LINK_ISSUER = "snapceipt-invoice";
const INVOICE_LINK_AUDIENCE = "snapceipt-invoice-link";

/** Sign an invoice-link token (iid + uid). `ttlSeconds` defaults to 30 days; a negative value
 *  lets tests mint an already-expired token. */
export async function signInvoiceLinkToken(
  signingKey: string,
  invoiceId: string,
  userId: string,
  ttlSeconds: number = INVOICE_LINK_TTL_SECONDS,
): Promise<string> {
  return new SignJWT({ iid: invoiceId, uid: userId })
    .setProtectedHeader({ alg: "HS256", typ: "JWT" })
    .setIssuer(INVOICE_LINK_ISSUER)
    .setAudience(INVOICE_LINK_AUDIENCE)
    .setIssuedAt()
    .setExpirationTime(`${ttlSeconds}s`)
    .sign(keyBytes(signingKey));
}

/** Verify an invoice-link token. Throws on any failure — the route maps a throw to 403. */
export async function verifyInvoiceLinkToken(
  signingKey: string,
  token: string,
): Promise<{ invoiceId: string; userId: string }> {
  const { payload } = await jwtVerify(token, keyBytes(signingKey), {
    issuer: INVOICE_LINK_ISSUER,
    audience: INVOICE_LINK_AUDIENCE,
    algorithms: ["HS256"],
  });
  const iid = (payload as { iid?: unknown }).iid;
  const uid = (payload as { uid?: unknown }).uid;
  if (typeof iid !== "string" || iid.length === 0 || typeof uid !== "string" || uid.length === 0) {
    throw new Error("invoice-link token missing iid/uid claim");
  }
  return { invoiceId: iid, userId: uid };
}
