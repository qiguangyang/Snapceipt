import { describe, it, expect } from "vitest";
import { SignJWT } from "jose";
import { signAccess, verifyAccess, newRefreshToken, hashToken } from "../src/lib/jwt";

const KEY = "test-signing-key-0123456789-abcdefghijklmnop";

describe("jwt", () => {
  it("signs and verifies an access token round-trip with all claims", async () => {
    const token = await signAccess(KEY, {
      userId: "u-1",
      sessionId: "s-1",
      deviceId: "d-1",
    });
    expect(typeof token).toBe("string");
    expect(token.split(".")).toHaveLength(3);

    const claims = await verifyAccess(KEY, token);
    expect(claims.sub).toBe("u-1");
    expect(claims.sid).toBe("s-1");
    expect(claims.did).toBe("d-1");
    expect(claims.iss).toBe("snapceipt");
    expect(claims.aud).toBe("snapceipt-ios");
    expect(claims.exp - claims.iat).toBe(900); // 15 min TTL
  });

  it("rejects a token signed with a different key (signature failure)", async () => {
    const token = await signAccess(KEY, { userId: "u-1", sessionId: "s-1", deviceId: "d-1" });
    await expect(verifyAccess("a-totally-different-key-9999999999", token)).rejects.toThrow();
  });

  it("rejects an expired token", async () => {
    // mint a token that expired one minute ago, with the correct iss/aud
    const secret = new TextEncoder().encode(KEY);
    const past = Math.floor(Date.now() / 1000) - 60;
    const expired = await new SignJWT({ sid: "s-1", did: "d-1" })
      .setProtectedHeader({ alg: "HS256" })
      .setSubject("u-1")
      .setIssuer("snapceipt")
      .setAudience("snapceipt-ios")
      .setIssuedAt(past - 900)
      .setExpirationTime(past)
      .sign(secret);
    await expect(verifyAccess(KEY, expired)).rejects.toThrow();
  });

  it("rejects a token with the wrong issuer/audience", async () => {
    const secret = new TextEncoder().encode(KEY);
    const wrong = await new SignJWT({ sid: "s-1", did: "d-1" })
      .setProtectedHeader({ alg: "HS256" })
      .setSubject("u-1")
      .setIssuer("evil")
      .setAudience("evil-app")
      .setIssuedAt()
      .setExpirationTime("15m")
      .sign(secret);
    await expect(verifyAccess(KEY, wrong)).rejects.toThrow();
  });

  it("newRefreshToken returns a 256-bit base64url string and hashToken is stable hex", async () => {
    const a = newRefreshToken();
    const b = newRefreshToken();
    expect(a).not.toBe(b);
    expect(a).toMatch(/^[A-Za-z0-9_-]+$/); // base64url, no padding
    // 32 random bytes -> base64url length 43
    expect(a.length).toBe(43);

    const h1 = await hashToken(a);
    const h2 = await hashToken(a);
    expect(h1).toBe(h2); // deterministic
    expect(h1).toMatch(/^[0-9a-f]{64}$/); // sha256 hex
    expect(await hashToken(b)).not.toBe(h1);
  });
});
