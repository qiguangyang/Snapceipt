import { SignJWT, jwtVerify } from "jose";

export const ACCESS_TTL_SECONDS = 600; // 10 minutes (lowered from 15 to shrink the post-revocation window; L3)
const ISSUER = "snapceipt";
const AUDIENCE = "snapceipt-ios";

export interface AccessClaims {
  sub: string; // userId
  sid: string; // sessionId
  did: string; // deviceId
  iss: string;
  aud: string;
  iat: number;
  exp: number;
}

function keyBytes(signingKey: string): Uint8Array {
  return new TextEncoder().encode(signingKey);
}

/** Sign a 15-minute HS256 access token. */
export async function signAccess(
  signingKey: string,
  input: { userId: string; sessionId: string; deviceId: string },
): Promise<string> {
  return new SignJWT({ sid: input.sessionId, did: input.deviceId })
    .setProtectedHeader({ alg: "HS256", typ: "JWT" })
    .setSubject(input.userId)
    .setIssuer(ISSUER)
    .setAudience(AUDIENCE)
    .setIssuedAt()
    .setExpirationTime(`${ACCESS_TTL_SECONDS}s`)
    .sign(keyBytes(signingKey));
}

/**
 * Verify an HS256 access token. Throws (jose JWTExpired / JWSSignatureVerificationFailed /
 * JWTClaimValidationFailed) on any failure — callers map this to AUTH_INVALID_TOKEN.
 */
export async function verifyAccess(signingKey: string, token: string): Promise<AccessClaims> {
  const { payload } = await jwtVerify(token, keyBytes(signingKey), {
    issuer: ISSUER,
    audience: AUDIENCE,
    algorithms: ["HS256"],
  });
  return payload as unknown as AccessClaims;
}

/** Opaque 256-bit refresh token, base64url (no padding) — 43 chars. */
export function newRefreshToken(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return base64url(bytes);
}

/** SHA-256 hex of a token; what we persist in the sessions table. */
export async function hashToken(token: string): Promise<string> {
  const data = new TextEncoder().encode(token);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function base64url(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
