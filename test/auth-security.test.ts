import { env, SELF } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as emailModule from "../src/lib/email";

// Migrations applied by test/apply-migrations.ts (vitest.config.ts setupFiles).
//
// Regression coverage for the auth-hardening findings:
//   L1 — per-EMAIL failed-login lockout (independent of source IP) on /auth/password/login.
//   L2 — constant-work password verify so a non-existent email returns the SAME uniform error.

const BASE = "https://x";

function installCodeSpy() {
  const send = vi.spyOn(emailModule, "sendSignInCode").mockResolvedValue(undefined);
  return {
    send,
    lastCode(): string {
      const arg = send.mock.calls.at(-1)?.[1] as { code?: string } | undefined;
      if (!arg?.code) throw new Error("no code in email payload");
      return arg.code;
    },
  };
}

afterEach(() => vi.restoreAllMocks());

/** Flush every fixed-window rate-limit counter so the many /auth/* calls below aren't 429'd by
 *  the per-IP (20/hr) tier — we want to exercise the per-EMAIL lockout in isolation. */
async function clearRateLimits() {
  const { keys } = await env.KV.list({ prefix: "rl:" });
  for (const k of keys) await env.KV.delete(k.name);
}

beforeEach(async () => {
  for (const t of ["sessions", "auth_identities", "devices", "users"]) {
    await env.DB.exec(`DELETE FROM ${t}`);
  }
  await clearRateLimits();
});

/** Sign up via the 6-digit code on a device (which TRUSTS the device) → access token. */
async function signUpWithCode(email: string, deviceId: string): Promise<string> {
  await clearRateLimits();
  const spy = installCodeSpy();
  await SELF.fetch(`${BASE}/auth/otp/request`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ email }),
  });
  const code = spy.lastCode();
  vi.restoreAllMocks();
  const res = await SELF.fetch(`${BASE}/auth/otp/verify`, {
    method: "POST",
    headers: { "content-type": "application/json", "X-Device-Id": deviceId },
    body: JSON.stringify({ email, code }),
  });
  expect(res.status).toBe(200);
  return ((await res.json()) as { accessToken: string }).accessToken;
}

async function setPassword(accessToken: string, deviceId: string, password: string) {
  await clearRateLimits();
  const res = await SELF.fetch(`${BASE}/auth/password/set`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${accessToken}`,
      "X-Device-Id": deviceId,
    },
    body: JSON.stringify({ password }),
  });
  expect(res.status).toBe(200);
}

/** One login attempt. `ip` simulates a distinct source via CF-Connecting-IP so the lockout's
 *  IP-independence is exercised; rate-limit counters are flushed first so only the lockout gates. */
async function login(email: string, password: string, deviceId: string, ip: string) {
  await clearRateLimits();
  return SELF.fetch(`${BASE}/auth/password/login`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "X-Device-Id": deviceId,
      "CF-Connecting-IP": ip,
    },
    body: JSON.stringify({ email, password }),
  });
}

async function codeOf(res: Response): Promise<string> {
  return ((await res.json()) as { error: { code: string } }).error.code;
}

describe("L1 — per-email failed-login lockout (distributed brute-force)", () => {
  it("locks the email after repeated wrong passwords from DIFFERENT IPs; correct password resets it", async () => {
    const email = "lockout@example.com";
    const dev = "dev-lock";
    const token = await signUpWithCode(email, dev); // trusts dev
    await setPassword(token, dev, "correcthorse1");

    // 9 wrong attempts, each from a DIFFERENT source IP (proves the counter is per-email, not
    // per-IP). All return the uniform 401 AUTH_INVALID_CREDENTIALS — not yet locked.
    for (let i = 0; i < 9; i++) {
      const res = await login(email, "wrongpass99", dev, `203.0.113.${i}`);
      expect(res.status).toBe(401);
      expect(await codeOf(res)).toBe("AUTH_INVALID_CREDENTIALS");
    }

    // 10th wrong attempt crosses the threshold → email is now locked (429 RATE_LIMITED).
    const trip = await login(email, "wrongpass99", dev, "203.0.113.99");
    expect(trip.status).toBe(429);
    expect(await codeOf(trip)).toBe("RATE_LIMITED");

    // Further attempts — even from yet another IP, and even with the CORRECT password — are
    // rejected during the cooldown (the lockout is checked before any password work).
    const duringCooldown = await login(email, "correcthorse1", dev, "198.51.100.7");
    expect(duringCooldown.status).toBe(429);
    expect(await codeOf(duringCooldown)).toBe("RATE_LIMITED");

    // Simulate the cooldown elapsing by clearing the lockout key, then a CORRECT password
    // succeeds AND resets the counter.
    const emailHash = await sha256Hex(email);
    await env.KV.delete(`pwl:${emailHash}`);
    const ok = await login(email, "correcthorse1", dev, "198.51.100.7");
    expect(ok.status).toBe(200);
    expect(((await ok.json()) as { accessToken?: string }).accessToken).toBeTruthy();
    // Counter cleared on success.
    expect(await env.KV.get(`pwl:${emailHash}`)).toBeNull();

    // And the email is no longer locked — a fresh wrong attempt is back to a plain 401, not 429.
    const after = await login(email, "wrongpass99", dev, "203.0.113.200");
    expect(after.status).toBe(401);
    expect(await codeOf(after)).toBe("AUTH_INVALID_CREDENTIALS");
  });

  it("a correct password well before the threshold keeps the account usable (no false lockout)", async () => {
    const email = "nofalse@example.com";
    const dev = "dev-ok";
    const token = await signUpWithCode(email, dev);
    await setPassword(token, dev, "correcthorse1");

    // A few stray typos, then the right password — must still log in.
    for (let i = 0; i < 3; i++) {
      const bad = await login(email, "typotypo1", dev, "203.0.113.1");
      expect(bad.status).toBe(401);
    }
    const ok = await login(email, "correcthorse1", dev, "203.0.113.1");
    expect(ok.status).toBe(200);
  });
});

describe("L2 — enumeration / timing oracle on /auth/password/login", () => {
  it("a non-existent email returns the SAME uniform 401 as a wrong password (constant-work verify)", async () => {
    // (timing itself isn't reliably unit-assertable; we assert the observable contract — identical
    //  status + error code — and rely on the dummy-hash verify for time-independence.)
    const missing = await login("ghost-no-such-user@example.com", "whatever123", "d", "203.0.113.5");
    expect(missing.status).toBe(401);
    expect(await codeOf(missing)).toBe("AUTH_INVALID_CREDENTIALS");

    // A real account with the WRONG password yields the byte-identical envelope.
    const email = "real-user@example.com";
    const dev = "dev-real";
    const token = await signUpWithCode(email, dev);
    await setPassword(token, dev, "correcthorse1");
    const wrong = await login(email, "whatever123", dev, "203.0.113.6");
    expect(wrong.status).toBe(401);
    expect(await codeOf(wrong)).toBe("AUTH_INVALID_CREDENTIALS");
  });

  it("an existing account that never set a password also returns the uniform 401", async () => {
    await signUpWithCode("nopw-sec@example.com", "d2"); // user exists, no password_hash
    const res = await login("nopw-sec@example.com", "whatever123", "d2", "203.0.113.7");
    expect(res.status).toBe(401);
    expect(await codeOf(res)).toBe("AUTH_INVALID_CREDENTIALS");
  });
});

/** SHA-256 hex — mirrors the server's KV-key derivation for the lockout key assertion. */
async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
