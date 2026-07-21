import { env, SELF } from "cloudflare:test";
import { afterEach, describe, expect, it, vi } from "vitest";
import * as emailModule from "../src/lib/email";
import { allowOtpSend } from "../src/routes/auth";

// Migrations applied by test/apply-migrations.ts (vitest.config.ts setupFiles).
// isolatedStorage is ON — each `it` gets a fresh D1/KV.

afterEach(() => {
  vi.restoreAllMocks();
});

async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function request(email: string) {
  return SELF.fetch("https://x/auth/otp/request", {
    method: "POST",
    headers: { "content-type": "application/json", "cf-connecting-ip": "198.51.100.7" },
    body: JSON.stringify({ email }),
  });
}

describe("OTP per-address daily send cap", () => {
  // (a) Deterministic, order-independent unit test of the cap itself. Calling the
  // helper directly avoids the per-IP / per-email hourly rate-limit tiers entirely
  // (Task 2 lowers the per-email cap to 4/hr, which would flake a 7-request HTTP test).
  it("allowOtpSend returns true for the first OTP_SEND_DAILY_CAP (6) calls, then false", async () => {
    const emailHash = "a".repeat(64); // any fixed sha256-shaped string
    const results: boolean[] = [];
    for (let i = 0; i < 7; i++) {
      results.push(await allowOtpSend(env.KV, emailHash));
    }
    expect(results).toEqual([true, true, true, true, true, true, false]);
  });

  // (b) Integration wiring test: prove sendOtpCode actually routes through the cap
  // and still writes the KV code + returns 202. 4 requests stays under every hourly
  // cap (per-IP 20/hr, per-email 8/hr now / 4/hr after Task 2) and under the daily cap.
  it("wires the cap into /auth/otp/request: each of 4 requests is 202 and sends an email", async () => {
    const send = vi.spyOn(emailModule, "sendSignInCode").mockResolvedValue(undefined);
    const email = "wireme@example.com";

    for (let i = 0; i < 4; i++) {
      const res = await request(email);
      expect(res.status).toBe(202);
    }
    expect(send).toHaveBeenCalledTimes(4);

    const emailHash = await sha256Hex(email);
    expect(await env.KV.get(`oc:${emailHash}`)).not.toBeNull();
  });
});
