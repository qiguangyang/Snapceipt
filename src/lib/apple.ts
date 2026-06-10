import {
  createLocalJWKSet,
  jwtVerify,
  decodeProtectedHeader,
  type JSONWebKeySet,
} from "jose";
import type { Env } from "../env";
import { ApiError } from "./errors";

// Sign in with Apple: verify the client-supplied identity JWT against Apple's
// published RS256 signing keys. We cache the JWKS in KV (Apple rotates keys
// rarely, so a ~24h TTL + refetch-on-kid-miss covers rollover) so we don't hit
// appleid.apple.com on every sign-in.

const APPLE_ISS = "https://appleid.apple.com";
const APPLE_JWKS_URL = "https://appleid.apple.com/auth/keys";
const JWKS_KV_KEY = "apple:jwks";
const JWKS_TTL_SECONDS = 60 * 60 * 24; // ~24h

export interface AppleClaims {
  sub: string;
  email?: string;
  email_verified?: boolean | string;
  nonce?: string;
  is_private_email?: boolean | string;
}

/** Fetch Apple's JWKS, preferring the KV cache. `force` bypasses the cache (kid rollover). */
export async function fetchAppleJwks(env: Env, force = false): Promise<JSONWebKeySet> {
  if (!force) {
    const cached = await env.KV.get(JWKS_KV_KEY);
    if (cached) return JSON.parse(cached) as JSONWebKeySet;
  }
  const res = await fetch(APPLE_JWKS_URL, { headers: { accept: "application/json" } });
  if (!res.ok) {
    throw new ApiError("AUTH_INVALID_TOKEN", "Unable to fetch Apple signing keys");
  }
  const jwks = (await res.json()) as JSONWebKeySet;
  await env.KV.put(JWKS_KV_KEY, JSON.stringify(jwks), { expirationTtl: JWKS_TTL_SECONDS });
  return jwks;
}

/** base64url(sha256(rawNonce)) — tolerated alternative client nonce encoding. */
async function sha256Base64Url(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  const bytes = new Uint8Array(digest);
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** lowercase hex(sha256(rawNonce)) — what the iOS client sets on
 *  ASAuthorizationAppleIDRequest.nonce (AppleNonce.sha256), and therefore what
 *  Apple embeds VERBATIM in the identity token's nonce claim. */
async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * Verify an Apple identity JWT. Returns the validated claims (incl. stable `sub`).
 * Enforces signature (RS256, matching kid), iss, aud (== env.APPLE_BUNDLE_ID),
 * exp, and the nonce (sha256(rawNonce) must equal payload.nonce). Any failure is
 * collapsed to a 401 AUTH_INVALID_TOKEN so the route never leaks specifics.
 */
export async function verifyAppleIdentityToken(
  env: Env,
  identityToken: string,
  rawNonce: string,
): Promise<AppleClaims> {
  // Pick the kid up front so we can refresh the cache if Apple rotated keys.
  let kid: string | undefined;
  try {
    kid = decodeProtectedHeader(identityToken).kid;
  } catch {
    throw new ApiError("AUTH_INVALID_TOKEN", "Malformed identity token");
  }

  const cached = await fetchAppleJwks(env, false);
  const hasKid = (jwks: JSONWebKeySet) => !kid || jwks.keys.some((k) => k.kid === kid);
  // Cache miss on this kid → Apple likely rotated keys; refetch once, bypassing cache.
  const jwks = hasKid(cached) ? cached : await fetchAppleJwks(env, true);

  let payload: AppleClaims;
  try {
    const result = await jwtVerify(identityToken, createLocalJWKSet(jwks), {
      issuer: APPLE_ISS,
      audience: env.APPLE_BUNDLE_ID,
      algorithms: ["RS256"],
    });
    payload = result.payload as unknown as AppleClaims;
  } catch {
    throw new ApiError("AUTH_INVALID_TOKEN", "Invalid Apple identity token");
  }

  // Apple embeds EXACTLY the string the client set on request.nonce — it does
  // NOT hash it again. Our iOS client sets the lowercase-hex sha256 digest;
  // base64url is tolerated for other client conventions.
  const expectedHex = await sha256Hex(rawNonce);
  const expectedB64 = await sha256Base64Url(rawNonce);
  if (!payload.nonce || (payload.nonce !== expectedHex && payload.nonce !== expectedB64)) {
    throw new ApiError("AUTH_INVALID_TOKEN", "Nonce mismatch");
  }
  if (!payload.sub) {
    throw new ApiError("AUTH_INVALID_TOKEN", "Missing subject");
  }
  return payload;
}
