import { SignJWT, exportJWK, generateKeyPair, type JSONWebKeySet } from "jose";

// In-test Apple stand-in: the real appleid.apple.com JWKS can't be reached from
// the test runtime, so we generate our own RS256 keypair, sign an Apple-shaped
// identity token with it, and export the matching public JWK as a JWKS. Tests
// serve that JWKS (via fetchMock or by pre-seeding the apple:jwks KV key) so the
// route verifies the token exactly as it would against Apple's real keys.

export const TEST_KID = "test-apple-kid-1";
export const APPLE_ISS = "https://appleid.apple.com";

// Each generated token gets a fresh kid by default so that a stale KV-cached
// JWKS (from a prior sign-in with a different in-test keypair) triggers the
// route's kid-miss refetch path — mirroring real Apple key rollover. Tests that
// specifically exercise the cache-hit path pass an explicit `kid`.
let kidCounter = 0;

async function sha256Base64Url(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  const bytes = new Uint8Array(digest);
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export interface MakeTokenOpts {
  sub?: string;
  aud: string;
  rawNonce: string;
  email?: string;
  iss?: string;
  kid?: string;
  expiresInSec?: number;
}

export interface AppleTestKit {
  jwks: JSONWebKeySet;
  token: string;
}

/** Build a signed Apple-style identity token plus the matching JWKS to serve from the mock. */
export async function makeAppleIdToken(opts: MakeTokenOpts): Promise<AppleTestKit> {
  const { publicKey, privateKey } = await generateKeyPair("RS256", { extractable: true });
  const kid = opts.kid ?? `${TEST_KID}-${++kidCounter}`;

  const publicJwk = await exportJWK(publicKey);
  publicJwk.kid = kid;
  publicJwk.alg = "RS256";
  publicJwk.use = "sig";
  const jwks: JSONWebKeySet = { keys: [publicJwk] };

  const now = Math.floor(Date.now() / 1000);
  const token = await new SignJWT({
    nonce: await sha256Base64Url(opts.rawNonce),
    email: opts.email,
    email_verified: opts.email ? "true" : undefined,
  })
    .setProtectedHeader({ alg: "RS256", kid })
    .setIssuer(opts.iss ?? APPLE_ISS)
    .setAudience(opts.aud)
    .setSubject(opts.sub ?? "000123.apple.subject.abc")
    .setIssuedAt(now)
    .setExpirationTime(now + (opts.expiresInSec ?? 600))
    .sign(privateKey);

  return { jwks, token };
}
