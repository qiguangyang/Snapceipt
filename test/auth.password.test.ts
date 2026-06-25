import { env, SELF } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as emailModule from "../src/lib/email";

// Migrations applied by test/apply-migrations.ts (vitest.config.ts setupFiles).

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

/** Reset every fixed-window rate-limit counter so this file's many /auth/* requests (well over
 *  the 10/IP/hr + 3/email/hr caps in aggregate) aren't 429'd — called before each auth request. */
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

const BASE = "https://x";

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
    headers: { "content-type": "application/json", authorization: `Bearer ${accessToken}`, "X-Device-Id": deviceId },
    body: JSON.stringify({ password }),
  });
  expect(res.status).toBe(200);
}

async function passwordLogin(email: string, password: string, deviceId: string) {
  await clearRateLimits();
  return SELF.fetch(`${BASE}/auth/password/login`, {
    method: "POST",
    headers: { "content-type": "application/json", "X-Device-Id": deviceId },
    body: JSON.stringify({ email, password }),
  });
}

describe("password auth", () => {
  it("password login on a TRUSTED device returns a session", async () => {
    const email = "pw@example.com";
    const dev = "dev-trusted";
    const token = await signUpWithCode(email, dev); // trusts dev
    await setPassword(token, dev, "supersecret1");

    const res = await passwordLogin(email, "supersecret1", dev);
    expect(res.status).toBe(200);
    const body = (await res.json()) as { accessToken?: string; mfaRequired?: boolean };
    expect(body.accessToken).toBeTruthy();
    expect(body.mfaRequired).toBeUndefined();
  });

  it("password login on a NEW device requires MFA (emails a code, no session) — then code trusts it", async () => {
    const email = "pw2@example.com";
    const token = await signUpWithCode(email, "dev-A");
    await setPassword(token, "dev-A", "supersecret1");

    const spy = installCodeSpy();
    const res = await passwordLogin(email, "supersecret1", "dev-NEW");
    expect(res.status).toBe(200);
    const body = (await res.json()) as { accessToken?: string; mfaRequired?: boolean };
    expect(body.mfaRequired).toBe(true);
    expect(body.accessToken).toBeUndefined();
    expect(spy.send).toHaveBeenCalledTimes(1);

    // Verify the MFA code on the new device → trusts it + issues a session.
    const code = spy.lastCode();
    await clearRateLimits();
    const v = await SELF.fetch(`${BASE}/auth/otp/verify`, {
      method: "POST",
      headers: { "content-type": "application/json", "X-Device-Id": "dev-NEW" },
      body: JSON.stringify({ email, code }),
    });
    expect(v.status).toBe(200);
    expect(((await v.json()) as { accessToken: string }).accessToken).toBeTruthy();

    // The new device is now trusted → password login there returns a session directly.
    const again = await passwordLogin(email, "supersecret1", "dev-NEW");
    expect(((await again.json()) as { accessToken?: string }).accessToken).toBeTruthy();
  });

  it("wrong password → 401 AUTH_INVALID_CREDENTIALS", async () => {
    const email = "pw3@example.com";
    const dev = "dev-x";
    const token = await signUpWithCode(email, dev);
    await setPassword(token, dev, "supersecret1");

    const res = await passwordLogin(email, "wrongwrong", dev);
    expect(res.status).toBe(401);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe("AUTH_INVALID_CREDENTIALS");
  });

  it("unknown email AND a passwordless account both return the same 401 (no enumeration)", async () => {
    const r1 = await passwordLogin("nobody@example.com", "whatever12", "d");
    expect(r1.status).toBe(401);
    expect(((await r1.json()) as { error: { code: string } }).error.code).toBe("AUTH_INVALID_CREDENTIALS");

    await signUpWithCode("nopw@example.com", "d2"); // user exists, never set a password
    const r2 = await passwordLogin("nopw@example.com", "whatever12", "d2");
    expect(r2.status).toBe(401);
    expect(((await r2.json()) as { error: { code: string } }).error.code).toBe("AUTH_INVALID_CREDENTIALS");
  });

  it("password/set requires authentication", async () => {
    const res = await SELF.fetch(`${BASE}/auth/password/set`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ password: "supersecret1" }),
    });
    expect(res.status).toBe(401);
  });
});
