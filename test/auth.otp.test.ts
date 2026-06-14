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
