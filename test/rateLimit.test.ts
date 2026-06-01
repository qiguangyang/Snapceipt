import { env, SELF, applyD1Migrations } from "cloudflare:test";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import * as emailModule from "../src/lib/email";
import { RATE_LIMIT_TIERS } from "../src/middleware/rateLimit";
import { ERROR } from "../src/lib/errors";

beforeAll(async () => {
  // Idempotent; the shared setup file applies these too, but keep the suite
  // self-contained per the task spec.
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

// The real SendEmail binding is not exercisable in the vitest-pool-workers
// runtime, so stub the email seam — every magic-link request then resolves to
// 202 and we can observe the rate limiter rather than an email-send failure.
afterEach(() => {
  vi.restoreAllMocks();
});

describe("rateLimit middleware", () => {
  it("returns 429 RATE_LIMITED with Retry-After after the magic-link IP window is exhausted", async () => {
    vi.spyOn(emailModule, "sendMagicLinkEmail").mockResolvedValue(undefined);

    const ip = "203.0.113.42";
    const send = (email: string) =>
      SELF.fetch("https://api.test/auth/magic-link/request", {
        method: "POST",
        headers: { "content-type": "application/json", "cf-connecting-ip": ip },
        body: JSON.stringify({ email }),
      });

    // 10 distinct emails from one IP are allowed (each email is under its own 3/hr cap).
    for (let i = 0; i < 10; i++) {
      const ok = await send(`u${i}@example.com`);
      expect(ok.status).toBe(202);
    }

    // 11th request from the same IP trips the 10/IP/hr ceiling.
    const blocked = await send("u11@example.com");
    expect(blocked.status).toBe(429);
    const retryAfter = blocked.headers.get("Retry-After");
    expect(retryAfter).not.toBeNull();
    expect(Number(retryAfter)).toBeGreaterThan(0);
    const body = (await blocked.json()) as { error: { code: string; requestId: string } };
    expect(body.error.code).toBe("RATE_LIMITED");
    expect(typeof body.error.requestId).toBe("string");
  });

  it("enforces the per-email cap (3/hr) independently of the IP cap", async () => {
    vi.spyOn(emailModule, "sendMagicLinkEmail").mockResolvedValue(undefined);

    // Each request uses a DISTINCT IP so the 10/IP/hr ceiling never trips; the
    // only limit in play is the 3/email/hr cap on a single repeated address.
    const email = "repeat@example.com";
    const send = (n: number) =>
      SELF.fetch("https://api.test/auth/magic-link/request", {
        method: "POST",
        headers: { "content-type": "application/json", "cf-connecting-ip": `198.51.100.${n}` },
        body: JSON.stringify({ email }),
      });

    for (let i = 0; i < 3; i++) {
      const ok = await send(i);
      expect(ok.status).toBe(202);
    }

    const blocked = await send(99);
    expect(blocked.status).toBe(429);
    expect(Number(blocked.headers.get("Retry-After"))).toBeGreaterThan(0);
    const body = (await blocked.json()) as { error: { code: string } };
    expect(body.error.code).toBe("RATE_LIMITED");
  });

  it("does not leak across route classes: /health stays unlimited + public", async () => {
    // /health is public + unlimited; this asserts the limiter does not leak
    // across route classes (a public route is never rate-limited).
    for (let i = 0; i < 15; i++) {
      const res = await SELF.fetch("https://api.test/health");
      expect(res.status).toBe(200);
    }
  });

  it("allows a protected route under its generous per-user tier across many calls", async () => {
    // A protected route (/devices/me) is keyed by userId under the default tier
    // (300/user/min); a handful of calls from one user must all pass the limiter
    // (they 401 on auth, which proves the limiter let them through to auth).
    for (let i = 0; i < 15; i++) {
      const res = await SELF.fetch("https://api.test/devices/me", {
        method: "PUT",
        body: "{}",
      });
      // No bearer -> 401 from auth (NOT 429 from the limiter).
      expect(res.status).toBe(401);
    }
  });
});

describe("F7 tiers + error codes", () => {
  it("defines an 'account' tier (per-user, hourly)", () => {
    expect(RATE_LIMIT_TIERS.account).toEqual({ name: "account", limit: 60, windowMs: 60 * 60 * 1000, dimension: "user" });
  });
  it("maps GONE to 410", () => {
    expect(ERROR.GONE).toBe(410);
  });
});
