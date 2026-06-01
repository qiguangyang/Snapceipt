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
