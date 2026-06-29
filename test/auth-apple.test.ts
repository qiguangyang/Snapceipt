import { env, SELF, fetchMock } from "cloudflare:test";
import { beforeEach, afterEach, describe, expect, it } from "vitest";
import { makeAppleIdToken, sha256Base64Url, TEST_KID } from "./helpers/apple";

// Migrations are applied by the shared setup file (test/apply-migrations.ts).

const BUNDLE_ID = env.APPLE_BUNDLE_ID;
const JWKS_KV_KEY = "apple:jwks";

beforeEach(async () => {
  // Clean auth state + the JWKS cache so each test controls what the route sees.
  await env.DB.exec("DELETE FROM sessions");
  await env.DB.exec("DELETE FROM auth_identities");
  await env.DB.exec("DELETE FROM devices");
  await env.DB.exec("DELETE FROM users");
  await env.KV.delete(JWKS_KV_KEY);
  fetchMock.activate();
  fetchMock.disableNetConnect();
});

afterEach(() => {
  fetchMock.assertNoPendingInterceptors();
});

/** Serve `jwks` from the mocked Apple JWKS endpoint exactly once. */
function mockJwks(jwks: unknown) {
  fetchMock
    .get("https://appleid.apple.com")
    .intercept({ path: "/auth/keys", method: "GET" })
    .reply(200, JSON.stringify(jwks), { headers: { "content-type": "application/json" } });
}

function post(body: unknown, headers: Record<string, string> = {}) {
  return SELF.fetch("https://api.test/auth/apple", {
    method: "POST",
    headers: { "content-type": "application/json", "x-device-id": crypto.randomUUID(), ...headers },
    body: JSON.stringify(body),
  });
}

describe("POST /auth/apple", () => {
  it("verifies a valid Apple token and issues a session", async () => {
    const rawNonce = "raw-nonce-success-001";
    const { jwks, token } = await makeAppleIdToken({
      aud: BUNDLE_ID,
      rawNonce,
      sub: "000777.apple.success",
      email: "relay@privaterelay.appleid.com",
    });
    mockJwks(jwks);

    const res = await post({
      identityToken: token,
      authorizationCode: "auth-code-xyz",
      rawNonce,
      fullName: "Maya Reyes",
      email: "relay@privaterelay.appleid.com",
    });

    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      accessToken: string;
      refreshToken: string;
      expiresIn: number;
      error?: unknown;
      user: { id: string; email: string | null; displayName: string | null };
    };
    // Success bodies are unwrapped (no { error } wrapper).
    expect(body.error).toBeUndefined();
    expect(typeof body.accessToken).toBe("string");
    expect(body.accessToken.split(".")).toHaveLength(3); // JWT
    expect(typeof body.refreshToken).toBe("string");
    expect(body.refreshToken.length).toBeGreaterThanOrEqual(40);
    expect(body.expiresIn).toBe(600);
    expect(body.user.id).toMatch(/[0-9a-f-]{36}/i);
    expect(body.user.email).toBe("relay@privaterelay.appleid.com");
    expect(body.user.displayName).toBe("Maya Reyes");

    // The apple identity is persisted and keyed by sub.
    const row = await env.DB.prepare(
      "SELECT user_id FROM auth_identities WHERE provider = 'apple' AND subject = ?1",
    )
      .bind("000777.apple.success")
      .first<{ user_id: string }>();
    expect(row?.user_id).toBe(body.user.id);
  });

  it("ignores a spoofed client email, trusting only the verified token email", async () => {
    const rawNonce = "raw-nonce-spoof-001";
    const { jwks, token } = await makeAppleIdToken({
      aud: BUNDLE_ID,
      rawNonce,
      sub: "000779.apple.spoof",
      email: "real@privaterelay.appleid.com", // the cryptographically-signed email
    });
    mockJwks(jwks);

    // Attacker sends a DIFFERENT email in the JSON body than the one in the token.
    const res = await post({
      identityToken: token,
      authorizationCode: "auth-code",
      rawNonce,
      fullName: "Mallory",
      email: "victim@gmail.com", // spoofed — must be ignored
    });

    expect(res.status).toBe(200);
    const body = (await res.json()) as { user: { id: string; email: string | null } };
    // The stored account email is the token's, never the client-supplied one.
    expect(body.user.email).toBe("real@privaterelay.appleid.com");

    const row = await env.DB.prepare("SELECT email FROM users WHERE id = ?1")
      .bind(body.user.id)
      .first<{ email: string | null }>();
    expect(row?.email).toBe("real@privaterelay.appleid.com");
  });

  it("rejects a REPLAYED identity token (single-use nonce)", async () => {
    const rawNonce = "raw-nonce-replay-001";
    const { jwks, token } = await makeAppleIdToken({
      aud: BUNDLE_ID,
      rawNonce,
      sub: "000777.apple.replay",
      email: "replay@privaterelay.appleid.com",
    });
    // Pre-seed the JWKS cache so both verifies read KV (no network), keeping this test
    // independent of fetch-mock interceptor accounting.
    await env.KV.put(JWKS_KV_KEY, JSON.stringify(jwks));

    const first = await post({ identityToken: token, authorizationCode: "auth-code-xyz", rawNonce });
    expect(first.status).toBe(200);

    // Replaying the same {identityToken, rawNonce} must be rejected (nonce consumed).
    const second = await post({ identityToken: token, authorizationCode: "auth-code-xyz", rawNonce });
    expect(second.status).toBe(401);
  });

  it("reuses the existing user on a second sign-in (Apple omits name/email)", async () => {
    const first = await makeAppleIdToken({
      aud: BUNDLE_ID,
      rawNonce: "raw-nonce-reuse-001",
      sub: "000778.apple.reuse",
      email: "reuse@privaterelay.appleid.com",
    });
    mockJwks(first.jwks);
    const r1 = await post({
      identityToken: first.token,
      authorizationCode: "auth-code-1",
      rawNonce: "raw-nonce-reuse-001",
      fullName: "First Last",
      email: "reuse@privaterelay.appleid.com",
    });
    expect(r1.status).toBe(200);
    const b1 = (await r1.json()) as { user: { id: string; email: string | null; displayName: string | null } };

    // Second sign-in: Apple sends neither fullName nor email; same sub.
    const second = await makeAppleIdToken({
      aud: BUNDLE_ID,
      rawNonce: "raw-nonce-reuse-002",
      sub: "000778.apple.reuse",
    });
    mockJwks(second.jwks);
    const r2 = await post({
      identityToken: second.token,
      authorizationCode: "auth-code-2",
      rawNonce: "raw-nonce-reuse-002",
    });
    expect(r2.status).toBe(200);
    const b2 = (await r2.json()) as { user: { id: string; email: string | null; displayName: string | null } };

    // Same user, and the first-auth name/email are NOT overwritten on re-auth.
    expect(b2.user.id).toBe(b1.user.id);
    expect(b2.user.email).toBe("reuse@privaterelay.appleid.com");
    expect(b2.user.displayName).toBe("First Last");

    const count = await env.DB.prepare(
      "SELECT COUNT(*) AS n FROM auth_identities WHERE provider = 'apple' AND subject = ?1",
    )
      .bind("000778.apple.reuse")
      .first<{ n: number }>();
    expect(count!.n).toBe(1);
  });

  it("accepts a base64url-encoded nonce digest (tolerated alternative client convention)", async () => {
    const rawNonce = "raw-nonce-b64url-001";
    const { jwks, token } = await makeAppleIdToken({
      aud: BUNDLE_ID,
      rawNonce,
      sub: "000791.apple.b64url",
      nonce: await sha256Base64Url(rawNonce), // not the hex default
    });
    mockJwks(jwks);

    const res = await post({
      identityToken: token,
      authorizationCode: "auth-code",
      rawNonce,
    });

    expect(res.status).toBe(200);
    const body = (await res.json()) as { user: { id: string } };
    expect(body.user.id).toMatch(/[0-9a-f-]{36}/i);
  });

  it("rejects a token whose nonce does not match (401 AUTH_INVALID_TOKEN)", async () => {
    const { jwks, token } = await makeAppleIdToken({
      aud: BUNDLE_ID,
      rawNonce: "the-real-nonce",
      sub: "000888.apple.badnonce",
    });
    mockJwks(jwks);

    const res = await post({
      identityToken: token,
      authorizationCode: "auth-code",
      rawNonce: "a-different-nonce", // mismatch
    });

    expect(res.status).toBe(401);
    const body = (await res.json()) as { error: { code: string; requestId: string } };
    expect(body.error.code).toBe("AUTH_INVALID_TOKEN");
    expect(typeof body.error.requestId).toBe("string");
  });

  it("rejects a token with the wrong audience (401 AUTH_INVALID_TOKEN)", async () => {
    const rawNonce = "wrong-aud-nonce";
    const { jwks, token } = await makeAppleIdToken({
      aud: "com.someone.else", // not env.APPLE_BUNDLE_ID
      rawNonce,
      sub: "000999.apple.badaud",
    });
    mockJwks(jwks);

    const res = await post({
      identityToken: token,
      authorizationCode: "auth-code",
      rawNonce,
    });

    expect(res.status).toBe(401);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe("AUTH_INVALID_TOKEN");
  });

  it("serves the JWKS from the KV cache without hitting the network", async () => {
    const rawNonce = "cache-hit-nonce";
    const { jwks, token } = await makeAppleIdToken({
      aud: BUNDLE_ID,
      rawNonce,
      sub: "001000.apple.cachehit",
    });
    // Pre-seed the cache; intentionally register NO fetch interceptor. If the
    // route hits the network, disableNetConnect() throws and the test fails.
    await env.KV.put(JWKS_KV_KEY, JSON.stringify(jwks));

    const res = await post({
      identityToken: token,
      authorizationCode: "auth-code",
      rawNonce,
    });

    expect(res.status).toBe(200);
    const body = (await res.json()) as { user: { id: string } };
    expect(body.user.id).toMatch(/[0-9a-f-]{36}/i);
  });

  it("refetches the JWKS when the cached set is missing the token's kid", async () => {
    const rawNonce = "refresh-on-miss-nonce";
    const { jwks, token } = await makeAppleIdToken({
      aud: BUNDLE_ID,
      rawNonce,
      sub: "001001.apple.rollover",
      kid: "rotated-kid-2",
    });
    // Stale cache: a JWKS that does NOT contain the token's kid. The route must
    // detect the kid miss and refetch (which we serve the fresh JWKS for).
    await env.KV.put(JWKS_KV_KEY, JSON.stringify({ keys: [{ kty: "RSA", kid: "old-kid", use: "sig", alg: "RS256", n: "stale", e: "AQAB" }] }));
    mockJwks(jwks);

    const res = await post({
      identityToken: token,
      authorizationCode: "auth-code",
      rawNonce,
    });

    expect(res.status).toBe(200);
    const body = (await res.json()) as { user: { id: string } };
    expect(body.user.id).toMatch(/[0-9a-f-]{36}/i);

    // The fresh JWKS (with the rotated kid) was written back to the cache.
    const cached = JSON.parse((await env.KV.get(JWKS_KV_KEY))!) as { keys: { kid?: string }[] };
    expect(cached.keys.some((k) => k.kid === "rotated-kid-2")).toBe(true);
  });
});
