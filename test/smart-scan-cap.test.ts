// test/smart-scan-cap.test.ts
// Tests for the free/Pro smart-scan cap in POST /extract.
//
// The route body is now the RAW receipt IMAGE bytes (image/jpeg); `source`/`capturedAt`/
// `requestId` ride as query params. The image goes straight to Gemini vision via
// runExtraction (same extractor as email-in). We exercise the cap path by setting
// GEMINI_API_KEY to a dummy value so stubGate is false:
//   - Over cap: short-circuits before any Gemini call → "needs review" receipt, no slot.
//   - Under cap: we mock globalThis.fetch with a Gemini-shaped response so the extractor
//     returns a real receipt; a Gemini throw/parse-failure → "needs review", no slot.
//
// For the under-cap increment, see smartScan.test.ts (lib TDD) which fully exercises
// incrementUsage directly — the route wires those same helpers.
import { env } from "cloudflare:test";
import { Hono } from "hono";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { AppEnv } from "../src/env";
import { requestId, registerErrorHandler } from "../src/middleware/error";
import { extractRoutes } from "../src/routes/extract";
import { nowMs } from "../src/lib/time";

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

// A non-empty raw image body (JPEG SOI marker + a few bytes) and its header.
const IMAGE_BODY = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0, 16, 1, 2, 3, 4]).buffer;
const POST_HEADERS = { "content-type": "image/jpeg" };

/** A Gemini-shaped fetch response carrying `obj` as the JSON receipt in the first candidate part. */
function mockGemini(obj: unknown) {
  return vi.fn(async () => ({
    ok: true,
    status: 200,
    json: async () => ({ candidates: [{ content: { parts: [{ text: JSON.stringify(obj) }] } }] }),
  })) as unknown as typeof fetch;
}

const ORIGINAL_FETCH = globalThis.fetch;

beforeEach(async () => {
  // Clear only tables relevant to these tests.
  await env.DB.exec("DELETE FROM smart_scan_usage");
  await env.DB.exec("DELETE FROM users");
});

afterEach(() => {
  globalThis.fetch = ORIGINAL_FETCH; // the under-cap tests swap fetch — always restore it.
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("POST /extract — stubGate path (no key)", () => {
  it("stub path: meta.capped is false, no smartScan field, no DB access needed", async () => {
    const app = appWith({ GEMINI_API_KEY: "", DB: env.DB });
    const res = await app.request("/extract?source=scan&capturedAt=2026-05-30", {
      method: "POST",
      headers: POST_HEADERS,
      body: IMAGE_BODY,
    });
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
  it("returns 200 with a needs-review receipt + meta.capped=true when free cap (30) is exhausted", async () => {
    const userId = "u-cap-test";
    const t = nowMs();

    // Seed user as free plan.
    await env.DB.prepare("INSERT INTO users (id, email, email_verified, plan, created_at, updated_at) VALUES (?, ?, 1, 'free', ?, ?)")
      .bind(userId, "cap@e.com", t, t).run();
    // Seed usage at cap (30).
    await env.DB.prepare("INSERT INTO smart_scan_usage (user_id, period, count, updated_at) VALUES (?, '2026-06', 30, ?)")
      .bind(userId, t).run();

    const app = appWith({ GEMINI_API_KEY: "g-dummy", DB: env.DB }, userId);
    // POST with a capturedAt in 2026-06 so currentPeriod matches.
    const res = await app.request("/extract?source=scan&capturedAt=2026-06-15", {
      method: "POST",
      headers: POST_HEADERS,
      body: IMAGE_BODY,
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;

    // Capped: a "needs review" draft (no AI), total 0.
    expect(body.meta.capped).toBe(true);
    expect(body.meta.stub).toBe(false);
    expect(body.receipt.needsReview).toBe(true);
    expect(body.receipt.total).toBe(0);
    expect(body.receipt.currencyCode).toBe("AUD");

    // smartScan metadata.
    expect(body.meta.smartScan).toBeDefined();
    expect(body.meta.smartScan.cap).toBe(30);
    expect(body.meta.smartScan.used).toBe(30);
    expect(body.meta.smartScan.plan).toBe("free");

    // Count must NOT have been incremented.
    const row = await env.DB.prepare("SELECT count FROM smart_scan_usage WHERE user_id = ? AND period = '2026-06'")
      .bind(userId).first<{ count: number }>();
    expect(row!.count).toBe(30);
  });

  it("uses env-override cap (SMART_SCAN_CAP_FREE=2) and caps at 2", async () => {
    const userId = "u-cap-test";
    const t = nowMs();
    await env.DB.prepare("INSERT INTO users (id, email, email_verified, plan, created_at, updated_at) VALUES (?, ?, 1, 'free', ?, ?)")
      .bind(userId, "cap2@e.com", t, t).run();
    await env.DB.prepare("INSERT INTO smart_scan_usage (user_id, period, count, updated_at) VALUES (?, '2026-06', 2, ?)")
      .bind(userId, t).run();

    const app = appWith({ GEMINI_API_KEY: "g-dummy", DB: env.DB, SMART_SCAN_CAP_FREE: "2" }, userId);
    const res = await app.request("/extract?source=scan&capturedAt=2026-06-15", {
      method: "POST",
      headers: POST_HEADERS,
      body: IMAGE_BODY,
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;
    expect(body.meta.capped).toBe(true);
    expect(body.meta.smartScan.cap).toBe(2);
  });
});

describe("POST /extract — pro plan cap", () => {
  it("cap for a pro user is 1000", async () => {
    const userId = "u-pro-test";
    const t = nowMs();
    await env.DB.prepare("INSERT INTO users (id, email, email_verified, plan, created_at, updated_at) VALUES (?, ?, 1, 'pro', ?, ?)")
      .bind(userId, "pro@e.com", t, t).run();
    // Set usage just below the default free cap (30) but far below pro cap (1000).
    await env.DB.prepare("INSERT INTO smart_scan_usage (user_id, period, count, updated_at) VALUES (?, '2026-06', 5, ?)")
      .bind(userId, t).run();

    // We verify the cap value is 1000 by hitting the capped scenario with usage=1000.
    await env.DB.prepare("UPDATE smart_scan_usage SET count = 1000 WHERE user_id = ? AND period = '2026-06'")
      .bind(userId).run();

    const app = appWith({ GEMINI_API_KEY: "g-dummy", DB: env.DB }, userId);
    const res = await app.request("/extract?source=scan&capturedAt=2026-06-15", {
      method: "POST",
      headers: POST_HEADERS,
      body: IMAGE_BODY,
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;
    expect(body.meta.capped).toBe(true);
    expect(body.meta.smartScan.cap).toBe(1000);
    expect(body.meta.smartScan.plan).toBe("pro");
  });
});

describe("POST /extract — no user row (new/deleted user)", () => {
  it("defaults to free plan when user row is absent", async () => {
    // Don't seed any user row — simulates plan read returning null.
    const userId = "u-no-row";
    const t = nowMs();
    // Seed usage at cap=30 so we get capped response (proves plan='free' was read).
    await env.DB.prepare("INSERT INTO smart_scan_usage (user_id, period, count, updated_at) VALUES (?, '2026-06', 30, ?)")
      .bind(userId, t).run();

    const app = appWith({ GEMINI_API_KEY: "g-dummy", DB: env.DB }, userId);
    const res = await app.request("/extract?source=scan&capturedAt=2026-06-15", {
      method: "POST",
      headers: POST_HEADERS,
      body: IMAGE_BODY,
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;
    expect(body.meta.capped).toBe(true);
    expect(body.meta.smartScan.cap).toBe(30);   // free cap
    expect(body.meta.smartScan.plan).toBe("free");
  });
});

describe("POST /extract — under cap, Gemini extraction succeeds", () => {
  it("returns the Gemini receipt and burns exactly one slot", async () => {
    const userId = "u-under-test";
    const t = nowMs();
    await env.DB.prepare(
      "INSERT INTO users (id, email, email_verified, plan, created_at, updated_at) VALUES (?, ?, 1, 'free', ?, ?)",
    ).bind(userId, "under@e.com", t, t).run();
    await env.DB.prepare(
      "INSERT INTO smart_scan_usage (user_id, period, count, updated_at) VALUES (?, '2026-06', 3, ?)",
    ).bind(userId, t).run();

    globalThis.fetch = mockGemini({
      merchant: "Coles", date: "2026-06-15", currencyCode: "AUD", total: 34.87, gst: 0.36,
      category: "groceries", deductible: 0, lineItems: [{ name: "Milk", price: 3.5 }], confidence: 0.9,
    });

    const app = appWith({ GEMINI_API_KEY: "g-dummy", DB: env.DB }, userId);
    const res = await app.request("/extract?source=scan&capturedAt=2026-06-15", {
      method: "POST",
      headers: POST_HEADERS,
      body: IMAGE_BODY,
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;

    expect(body.meta.capped).toBe(false);
    expect(body.meta.stub).toBe(false);
    expect(body.receipt.merchant).toBe("Coles");
    expect(body.receipt.total).toBe(34.87);
    // (confidence/needsReview is graded server-side; the Gemini path has no OCR text to
    // boost it, so we don't pin needsReview here — the slot-burn is what this test guards.)

    // One slot burned: used reported as 4, DB count == 4.
    expect(body.meta.smartScan.used).toBe(4);
    expect(body.meta.smartScan.plan).toBe("free");
    const row = await env.DB.prepare(
      "SELECT count FROM smart_scan_usage WHERE user_id = ? AND period = '2026-06'",
    ).bind(userId).first<{ count: number }>();
    expect(row!.count).toBe(4);
  });
});

describe("POST /extract — LLM outage does NOT burn a smart-scan slot (Fix 1)", () => {
  it("does not increment usage counter when Gemini fails and the route returns needs-review", async () => {
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

    // Stub fetch to a non-OK response so runGeminiVisionExtraction throws → runExtraction
    // throws → the route catches → needs-review + NO usage increment.
    globalThis.fetch = vi.fn(async () => ({
      ok: false,
      status: 500,
      text: async () => "upstream error",
    })) as unknown as typeof fetch;

    const app = appWith({ GEMINI_API_KEY: "g-dummy", DB: env.DB }, userId);
    const res = await app.request("/extract?source=scan&capturedAt=2026-06-15", {
      method: "POST",
      headers: POST_HEADERS,
      body: IMAGE_BODY,
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

    // Receipt is the needs-review draft (no AI result through no fault of the user's).
    expect(body.receipt.needsReview).toBe(true);
    expect(body.receipt.total).toBe(0);
  });
});
