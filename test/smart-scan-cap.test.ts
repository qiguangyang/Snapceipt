// test/smart-scan-cap.test.ts
// Tests for the free/Pro smart-scan cap in POST /extract.
//
// Strategy: use the same appWith() pattern as extract-route.test.ts, but pass
// env.DB from cloudflare:test as the DB binding so D1 reads/writes are real.
// We set DEEPSEEK_API_KEY to a dummy value ("sk-dummy") so stubGate is false,
// which exercises the cap path WITHOUT making real DeepSeek network calls —
// the capped branch short-circuits before calling DeepSeek, and the under-cap
// branch will attempt a real call but we only test the capped scenario here.
//
// For the under-cap increment, see smartScan.test.ts (lib TDD) which fully
// exercises incrementUsage directly — the route wires those same helpers.
import { env } from "cloudflare:test";
import { Hono } from "hono";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { AppEnv } from "../src/env";
import { requestId, registerErrorHandler } from "../src/middleware/error";
import { extractRoutes } from "../src/routes/extract";
import { nowMs } from "../src/lib/time";

const OCR = ["THE GROUNDS", "28/05/2026", "Flat White 9.00", "Big Brekkie 24.00", "TOTAL 33.00"].join("\n");

function appWith(envOverrides: Record<string, unknown>, userId = "u-cap-test") {
  const app = new Hono<AppEnv>();
  app.use("*", requestId());
  registerErrorHandler(app);
  app.use("*", async (c, next) => {
    c.set("userId", userId);
    c.set("deviceId", "d-cap-test");
    await next();
  });
  app.route("/extract", extractRoutes);
  return {
    request: (path: string, init: RequestInit) => app.request(path, init, envOverrides),
  };
}

const POST_BODY = JSON.stringify({ ocrText: OCR, source: "scan", capturedAt: "2026-05-30" });
const POST_HEADERS = { "content-type": "application/json" };

beforeEach(async () => {
  // Clear only tables relevant to these tests.
  await env.DB.exec("DELETE FROM smart_scan_usage");
  await env.DB.exec("DELETE FROM users");
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("POST /extract — stubGate path (no key)", () => {
  it("stub path: meta.capped is false, no smartScan field, no DB access needed", async () => {
    const app = appWith({ DEEPSEEK_API_KEY: "", DB: env.DB });
    const res = await app.request("/extract", { method: "POST", headers: POST_HEADERS, body: POST_BODY });
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;
    expect(body.meta.stub).toBe(true);
    expect(body.meta.capped).toBe(false);
    // smartScan is not emitted on the stub path.
    expect(body.meta.smartScan).toBeUndefined();
    // Count should remain 0 — stub never increments.
    const row = await env.DB.prepare("SELECT COUNT(*) c FROM smart_scan_usage").first<{ c: number }>();
    expect(row!.c).toBe(0);
  });
});

describe("POST /extract — capped branch (free user at cap)", () => {
  it("returns 200 with heuristic receipt + meta.capped=true when free cap (10) is exhausted", async () => {
    const userId = "u-cap-test";
    const t = nowMs();

    // Seed user as free plan.
    await env.DB.prepare("INSERT INTO users (id, email, email_verified, plan, created_at, updated_at) VALUES (?, ?, 1, 'free', ?, ?)")
      .bind(userId, "cap@e.com", t, t).run();
    // Seed usage at cap (10).
    await env.DB.prepare("INSERT INTO smart_scan_usage (user_id, period, count, updated_at) VALUES (?, '2026-06', 10, ?)")
      .bind(userId, t).run();

    const app = appWith({ DEEPSEEK_API_KEY: "sk-dummy", DB: env.DB }, userId);
    // POST with a capturedAt in 2026-06 so currentPeriod matches.
    const res = await app.request("/extract", {
      method: "POST",
      headers: POST_HEADERS,
      body: JSON.stringify({ ocrText: OCR, source: "scan", capturedAt: "2026-06-15" }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;

    // Capped: heuristic receipt with needsReview true.
    expect(body.meta.capped).toBe(true);
    expect(body.meta.stub).toBe(false);
    expect(body.receipt.needsReview).toBe(true);
    // confidence is now graded (0.30–0.75) from found signals, not a hardcoded value.
    expect(body.receipt.confidence).toBeGreaterThanOrEqual(0.3);
    expect(body.receipt.confidence).toBeLessThanOrEqual(0.75);
    expect(body.receipt.currencyCode).toBe("AUD");

    // smartScan metadata.
    expect(body.meta.smartScan).toBeDefined();
    expect(body.meta.smartScan.cap).toBe(10);
    expect(body.meta.smartScan.used).toBe(10);
    expect(body.meta.smartScan.plan).toBe("free");

    // Count must NOT have been incremented.
    const row = await env.DB.prepare("SELECT count FROM smart_scan_usage WHERE user_id = ? AND period = '2026-06'")
      .bind(userId).first<{ count: number }>();
    expect(row!.count).toBe(10);
  });

  it("uses env-override cap (SMART_SCAN_CAP_FREE=2) and caps at 2", async () => {
    const userId = "u-cap-test";
    const t = nowMs();
    await env.DB.prepare("INSERT INTO users (id, email, email_verified, plan, created_at, updated_at) VALUES (?, ?, 1, 'free', ?, ?)")
      .bind(userId, "cap2@e.com", t, t).run();
    await env.DB.prepare("INSERT INTO smart_scan_usage (user_id, period, count, updated_at) VALUES (?, '2026-06', 2, ?)")
      .bind(userId, t).run();

    const app = appWith({ DEEPSEEK_API_KEY: "sk-dummy", DB: env.DB, SMART_SCAN_CAP_FREE: "2" }, userId);
    const res = await app.request("/extract", {
      method: "POST",
      headers: POST_HEADERS,
      body: JSON.stringify({ ocrText: OCR, source: "scan", capturedAt: "2026-06-15" }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;
    expect(body.meta.capped).toBe(true);
    expect(body.meta.smartScan.cap).toBe(2);
  });
});

describe("POST /extract — pro plan cap", () => {
  it("cap for a pro user is 500", async () => {
    const userId = "u-pro-test";
    const t = nowMs();
    await env.DB.prepare("INSERT INTO users (id, email, email_verified, plan, created_at, updated_at) VALUES (?, ?, 1, 'pro', ?, ?)")
      .bind(userId, "pro@e.com", t, t).run();
    // Set usage just below the default free cap (10) but far below pro cap (500).
    await env.DB.prepare("INSERT INTO smart_scan_usage (user_id, period, count, updated_at) VALUES (?, '2026-06', 5, ?)")
      .bind(userId, t).run();

    // We verify the cap value is 500 by hitting the capped scenario with usage=500.
    await env.DB.prepare("UPDATE smart_scan_usage SET count = 500 WHERE user_id = ? AND period = '2026-06'")
      .bind(userId).run();

    const app = appWith({ DEEPSEEK_API_KEY: "sk-dummy", DB: env.DB }, userId);
    const res = await app.request("/extract", {
      method: "POST",
      headers: POST_HEADERS,
      body: JSON.stringify({ ocrText: OCR, source: "scan", capturedAt: "2026-06-15" }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;
    expect(body.meta.capped).toBe(true);
    expect(body.meta.smartScan.cap).toBe(500);
    expect(body.meta.smartScan.plan).toBe("pro");
  });
});

describe("POST /extract — no user row (new/deleted user)", () => {
  it("defaults to free plan when user row is absent", async () => {
    // Don't seed any user row — simulates plan read returning null.
    const userId = "u-no-row";
    const t = nowMs();
    // Seed usage at cap=10 so we get capped response (proves plan='free' was read).
    await env.DB.prepare("INSERT INTO smart_scan_usage (user_id, period, count, updated_at) VALUES (?, '2026-06', 10, ?)")
      .bind(userId, t).run();

    const app = appWith({ DEEPSEEK_API_KEY: "sk-dummy", DB: env.DB }, userId);
    const res = await app.request("/extract", {
      method: "POST",
      headers: POST_HEADERS,
      body: JSON.stringify({ ocrText: OCR, source: "scan", capturedAt: "2026-06-15" }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;
    expect(body.meta.capped).toBe(true);
    expect(body.meta.smartScan.cap).toBe(10);   // free cap
    expect(body.meta.smartScan.plan).toBe("free");
  });
});

describe("POST /extract — LLM outage does NOT burn a smart-scan slot (Fix 1)", () => {
  it("does not increment usage counter when DeepSeek exhausts all attempts and falls back to heuristic", async () => {
    const userId = "u-outage-test";
    const t = nowMs();

    // Seed user as free plan with 3 scans already used.
    await env.DB.prepare(
      "INSERT INTO users (id, email, email_verified, plan, created_at, updated_at) VALUES (?, ?, 1, 'free', ?, ?)",
    )
      .bind(userId, "outage@e.com", t, t)
      .run();
    await env.DB.prepare(
      "INSERT INTO smart_scan_usage (user_id, period, count, updated_at) VALUES (?, '2026-06', 3, ?)",
    )
      .bind(userId, t)
      .run();

    // Stub fetch to always return unparseable content so runDeepseekExtraction
    // exhausts all 3 attempts and falls back to heuristic (usedLlm: false).
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue(
        new Response(
          JSON.stringify({ choices: [{ message: { content: "not valid json at all" } }] }),
          { status: 200, headers: { "content-type": "application/json" } },
        ),
      ),
    );

    const app = appWith({ DEEPSEEK_API_KEY: "sk-dummy", DB: env.DB }, userId);
    const res = await app.request("/extract", {
      method: "POST",
      headers: POST_HEADERS,
      body: JSON.stringify({ ocrText: OCR, source: "scan", capturedAt: "2026-06-15" }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;

    // Not capped — the slot was not consumed.
    expect(body.meta.capped).toBe(false);
    // smartScan.used must equal the prior count (3), NOT 4.
    expect(body.meta.smartScan).toBeDefined();
    expect(body.meta.smartScan.used).toBe(3);
    expect(body.meta.smartScan.plan).toBe("free");

    // Verify directly in DB that the counter was not incremented.
    const row = await env.DB.prepare(
      "SELECT count FROM smart_scan_usage WHERE user_id = ? AND period = '2026-06'",
    )
      .bind(userId)
      .first<{ count: number }>();
    expect(row!.count).toBe(3);

    // Receipt came from heuristic fallback (needsReview true; graded confidence 0.30–0.75).
    expect(body.receipt.needsReview).toBe(true);
    expect(body.receipt.confidence).toBeGreaterThanOrEqual(0.3);
    expect(body.receipt.confidence).toBeLessThanOrEqual(0.75);
  });
});
