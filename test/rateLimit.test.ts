import { env, SELF, applyD1Migrations } from "cloudflare:test";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import * as emailModule from "../src/lib/email";
import { RATE_LIMIT_TIERS, consume } from "../src/middleware/rateLimit";
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

    // 20 distinct emails from one IP are allowed (each email is under its own 4/hr cap).
    for (let i = 0; i < 20; i++) {
      const ok = await send(`u${i}@example.com`);
      expect(ok.status).toBe(202);
    }

    // 21st request from the same IP trips the 20/IP/hr ceiling.
    const blocked = await send("u21@example.com");
    expect(blocked.status).toBe(429);
    const retryAfter = blocked.headers.get("Retry-After");
    expect(retryAfter).not.toBeNull();
    expect(Number(retryAfter)).toBeGreaterThan(0);
    const body = (await blocked.json()) as { error: { code: string; requestId: string } };
    expect(body.error.code).toBe("RATE_LIMITED");
    expect(typeof body.error.requestId).toBe("string");
  });

  it("enforces the per-email cap (4/hr) on SENDS independently of the IP cap", async () => {
    vi.spyOn(emailModule, "sendMagicLinkEmail").mockResolvedValue(undefined);

    // Each request uses a DISTINCT IP so the 20/IP/hr ceiling never trips; the
    // only limit in play is the 4/email/hr cap on a single repeated address.
    const email = "repeat@example.com";
    const send = (n: number) =>
      SELF.fetch("https://api.test/auth/magic-link/request", {
        method: "POST",
        headers: { "content-type": "application/json", "cf-connecting-ip": `198.51.100.${n}` },
        body: JSON.stringify({ email }),
      });

    for (let i = 0; i < 4; i++) {
      const ok = await send(i);
      expect(ok.status).toBe(202);
    }

    const blocked = await send(99);
    expect(blocked.status).toBe(429);
    expect(Number(blocked.headers.get("Retry-After"))).toBeGreaterThan(0);
    const body = (await blocked.json()) as { error: { code: string } };
    expect(body.error.code).toBe("RATE_LIMITED");
  });

  it("EXEMPTS /auth/otp/verify from the per-email cap (it has its own per-code attempt cap)", async () => {
    // 12 verify attempts for the SAME email, each from a distinct IP (so the per-IP cap never
    // trips). Verify is exempt from the 4/email/hr cap, so none are 429 — they 401 on the missing
    // code. If verify still counted toward the email cap, the 9th would be RATE_LIMITED (the bug).
    const email = "verifyexempt@example.com";
    for (let i = 0; i < 12; i++) {
      const res = await SELF.fetch("https://api.test/auth/otp/verify", {
        method: "POST",
        headers: { "content-type": "application/json", "cf-connecting-ip": `198.51.100.${i + 1}` },
        body: JSON.stringify({ email, code: "000000" }),
      });
      expect(res.status).not.toBe(429);
      expect(res.status).toBe(401); // AUTH_INVALID_TOKEN — no pending code, but NOT rate-limited
    }
  });

  it("EXEMPTS /auth/password/login from the per-email send cap (failed logins don't burn it)", async () => {
    // 9 password-login attempts for the SAME email, each from a distinct IP. password/login is
    // exempt from the 4/email/hr SEND cap, so none are 429 — they 401 on bad credentials. If it
    // counted toward the 4/email send cap, the 9th would be RATE_LIMITED. (Stops at 9: the
    // SEPARATE per-email failed-login lockout (L1) trips at the 10th failure — covered in
    // test/auth-security.test.ts.)
    const email = "pwloginexempt@example.com";
    for (let i = 0; i < 9; i++) {
      const res = await SELF.fetch("https://api.test/auth/password/login", {
        method: "POST",
        headers: { "content-type": "application/json", "cf-connecting-ip": `198.51.100.${i + 1}` },
        body: JSON.stringify({ email, password: "whatever12" }),
      });
      expect(res.status).not.toBe(429);
      expect(res.status).toBe(401); // AUTH_INVALID_CREDENTIALS — bad creds, NOT rate-limited
    }
  });

  it("repeated failed password logins do NOT block a later code request (the reported bug)", async () => {
    // The exact user scenario: tap "Sign in" (password) several times with no/wrong password from
    // one device, then "Email me a code". Pre-fix the password/login attempts burned the
    // 4/email/hr send cap and the otp/request 429'd; post-fix password/login is exempt, so the
    // code request sends.
    vi.spyOn(emailModule, "sendSignInCode").mockResolvedValue(undefined);
    const email = "fumbler@example.com";
    const ip = "203.0.113.99";
    // 9 attempts: stay under the L1 per-email failed-login lockout (trips at the 10th); the
    // point here is that password failures don't block the later OTP code request.
    for (let i = 0; i < 9; i++) {
      const login = await SELF.fetch("https://api.test/auth/password/login", {
        method: "POST",
        headers: { "content-type": "application/json", "cf-connecting-ip": ip },
        body: JSON.stringify({ email, password: "nope12345" }),
      });
      expect(login.status).toBe(401);
    }
    const code = await SELF.fetch("https://api.test/auth/otp/request", {
      method: "POST",
      headers: { "content-type": "application/json", "cf-connecting-ip": ip },
      body: JSON.stringify({ email }),
    });
    expect(code.status).toBe(202); // code sent — NOT 429
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

describe("authIpDay tier", () => {
  it("blocks the 61st auth op from one IP within a UTC day (across hour buckets)", async () => {
    const tier = RATE_LIMIT_TIERS.authIpDay;
    expect(tier.limit).toBe(60);
    const identity = "ip:203.0.113.99";
    // All 60 calls must land in the SAME day bucket (floor(now/DAY) constant) while spanning
    // multiple HOURLY buckets. Anchor `base` to a UTC-day boundary and step 20 min/call: 60 steps
    // = 20h < 24h, so the day bucket stays constant (the counter reaches 60) yet the calls cross
    // ~20 different hour buckets. (A >1h step over 60 calls would span 61h and cross day buckets,
    // so the day counter would never reach 60 — 24h holds at most 24 one-per-hour calls.)
    const DAY = 24 * 60 * 60 * 1000;
    const STEP = 20 * 60 * 1000; // 20 min — crosses hour buckets, keeps all 60 inside one day
    const base = Math.floor(1_700_000_000_000 / DAY) * DAY; // start of a UTC day
    let last: number | null = 0;
    for (let i = 0; i < 60; i++) {
      last = await consume(env.KV, tier, identity, base + i * STEP);
      expect(last).toBeNull(); // first 60 permitted
    }
    const blocked = await consume(env.KV, tier, identity, base + 60 * STEP);
    expect(blocked).not.toBeNull(); // 61st blocked
    expect(blocked!).toBeGreaterThan(0);
  });
});
