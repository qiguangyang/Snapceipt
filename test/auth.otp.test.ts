import { env, SELF } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as emailModule from "../src/lib/email";

// Migrations applied by test/apply-migrations.ts (vitest.config.ts setupFiles).

async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function installCodeSpy() {
  const send = vi.spyOn(emailModule, "sendSignInCode").mockResolvedValue(undefined);
  return {
    send,
    lastCode() {
      const arg = send.mock.calls.at(-1)?.[1] as { code?: string } | undefined;
      if (!arg?.code) throw new Error("no code in email payload");
      return arg.code;
    },
  };
}

afterEach(() => {
  vi.restoreAllMocks();
});

describe("POST /auth/otp/request", () => {
  beforeEach(async () => {
    await env.DB.exec("DELETE FROM sessions");
    await env.DB.exec("DELETE FROM auth_identities");
    await env.DB.exec("DELETE FROM devices");
    await env.DB.exec("DELETE FROM users");
  });

  it("returns 202, writes oc:<emailhash> with a 6-digit codeHash, and emails the code", async () => {
    const spy = installCodeSpy();
    const res = await SELF.fetch("https://x/auth/otp/request", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ email: "Otp@Example.com " }),
    });
    expect(res.status).toBe(202);
    expect(spy.send).toHaveBeenCalledTimes(1);
    const code = spy.lastCode();
    expect(code).toMatch(/^\d{6}$/);

    const emailHash = await sha256Hex("otp@example.com");
    const raw = await env.KV.get(`oc:${emailHash}`);
    expect(raw).not.toBeNull();
    const pending = JSON.parse(raw!) as { codeHash: string; email: string; attempts: number };
    expect(pending.email).toBe("otp@example.com");
    expect(pending.attempts).toBe(0);
    expect(pending.codeHash).toBe(await sha256Hex(code));
  });

  it("returns 202 for an unknown email too (no enumeration)", async () => {
    const spy = installCodeSpy();
    const res = await SELF.fetch("https://x/auth/otp/request", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ email: "nobody-otp@example.com" }),
    });
    expect(res.status).toBe(202);
    expect(spy.send).toHaveBeenCalledTimes(1);
  });

  it("rejects a malformed email with 400 VALIDATION_FAILED", async () => {
    installCodeSpy();
    const res = await SELF.fetch("https://x/auth/otp/request", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ email: "nope" }),
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe("VALIDATION_FAILED");
  });
});

describe("POST /auth/otp/verify", () => {
  beforeEach(async () => {
    await env.DB.exec("DELETE FROM sessions");
    await env.DB.exec("DELETE FROM auth_identities");
    await env.DB.exec("DELETE FROM devices");
    await env.DB.exec("DELETE FROM users");
  });

  async function requestCode(email: string): Promise<string> {
    const spy = installCodeSpy();
    const res = await SELF.fetch("https://x/auth/otp/request", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ email }),
    });
    expect(res.status).toBe(202);
    return spy.lastCode();
  }

  it("consumes the code, creates the user + email identity, registers the device, returns a session", async () => {
    const code = await requestCode("otp-ok@example.com");
    const res = await SELF.fetch("https://x/auth/otp/verify", {
      method: "POST",
      headers: { "content-type": "application/json", "x-device-id": "01890000-0000-7000-8000-0000000otpdv" },
      body: JSON.stringify({ email: "otp-ok@example.com", code }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      accessToken: string; refreshToken: string; expiresIn: number;
      user: { id: string; email: string };
    };
    expect(body.expiresIn).toBe(900);
    expect(body.accessToken.split(".")).toHaveLength(3);
    expect(body.user.email).toBe("otp-ok@example.com");

    const ident = await env.DB
      .prepare("SELECT id FROM auth_identities WHERE provider = 'email' AND subject = ?")
      .bind("otp-ok@example.com").first();
    expect(ident).not.toBeNull();
    const device = await env.DB
      .prepare("SELECT id FROM devices WHERE id = ?")
      .bind("01890000-0000-7000-8000-0000000otpdv").first();
    expect(device).not.toBeNull();
  });

  it("locks out after 5 wrong attempts: attempts 1–4 → 400/VALIDATION_FAILED, attempt 5 → 401/AUTH_INVALID_TOKEN", async () => {
    const email = "otp-cap@example.com";
    const realCode = await requestCode(email);
    // Derive a guaranteed-wrong code: increment by 1 mod 1_000_000.
    // This is never equal to realCode so the test is deterministic.
    const wrongCode = ((parseInt(realCode, 10) + 1) % 1_000_000).toString().padStart(6, "0");

    // The auth rate limiter allows 3/email/hr. Flush the per-email counter after the
    // requestCode call so the 5 verify attempts start with a fresh window for this email.
    // Key format: rl:auth-email:email:${email}:${hourBucket} (rateLimit.ts consume()).
    const hourBucket = Math.floor(Date.now() / (60 * 60 * 1000));
    const rlEmailKey = `rl:auth-email:email:${email}:${hourBucket}`;
    const rlIpKey = `rl:auth-ip:ip:unknown:${hourBucket}`;
    async function resetRateLimits() {
      await env.KV.delete(rlEmailKey);
      await env.KV.delete(rlIpKey);
    }

    // Attempts 1–4: wrong code → 400 VALIDATION_FAILED; code stays live.
    for (let attempt = 1; attempt <= 4; attempt++) {
      await resetRateLimits();
      const res = await SELF.fetch("https://x/auth/otp/verify", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ email, code: wrongCode }),
      });
      expect(res.status).toBe(400);
      const body = (await res.json()) as { error: { code: string } };
      expect(body.error.code).toBe("VALIDATION_FAILED");
    }

    // Attempt 5 (at the cap): backend deletes the KV key → 401 AUTH_INVALID_TOKEN.
    await resetRateLimits();
    const capRes = await SELF.fetch("https://x/auth/otp/verify", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ email, code: wrongCode }),
    });
    expect(capRes.status).toBe(401);
    const capBody = (await capRes.json()) as { error: { code: string } };
    expect(capBody.error.code).toBe("AUTH_INVALID_TOKEN");

    // Code is now consumed — even the real code yields 401.
    await resetRateLimits();
    const afterCapRes = await SELF.fetch("https://x/auth/otp/verify", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ email, code: realCode }),
    });
    expect(afterCapRes.status).toBe(401);
    const afterCapBody = (await afterCapRes.json()) as { error: { code: string } };
    expect(afterCapBody.error.code).toBe("AUTH_INVALID_TOKEN");
  });

  it("rejects with 401 AUTH_INVALID_TOKEN when no code was requested for that email", async () => {
    const res = await SELF.fetch("https://x/auth/otp/verify", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ email: "never-requested@example.com", code: "123456" }),
    });
    expect(res.status).toBe(401);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe("AUTH_INVALID_TOKEN");
  });

  it("is single-use: a second verify with the same code 401s", async () => {
    const code = await requestCode("otp-once@example.com");
    const ok = await SELF.fetch("https://x/auth/otp/verify", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ email: "otp-once@example.com", code }),
    });
    expect(ok.status).toBe(200);
    const replay = await SELF.fetch("https://x/auth/otp/verify", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ email: "otp-once@example.com", code }),
    });
    expect(replay.status).toBe(401);
    const body = (await replay.json()) as { error: { code: string } };
    expect(body.error.code).toBe("AUTH_INVALID_TOKEN");
  });
});
