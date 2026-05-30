// test/extract-route.test.ts
import { Hono } from "hono";
import { describe, expect, it } from "vitest";
import type { AppEnv } from "../src/env";
import { requestId, registerErrorHandler } from "../src/middleware/error";
import { extractRoutes } from "../src/routes/extract";

/** Build a standalone app that mounts /extract with a fixed authed userId and a
 *  given env (no global auth/rate-limit — those are exercised in the app-mount + e2e tasks).
 *
 *  Returns a `request(path, init)` helper that threads `envOverrides` through
 *  Hono's `app.request(input, init, env)` 3rd arg so `c.env` is defined even in
 *  the vitest-pool-workers runtime (where a bare `app.request` leaves `c.env`
 *  undefined — the real worker env is only injected via the mounted app/SELF). */
function appWith(envOverrides: Record<string, unknown>) {
  const app = new Hono<AppEnv>();
  app.use("*", requestId());
  registerErrorHandler(app);
  // Inject a fake authed identity (env arrives via the request() helper below).
  app.use("*", async (c, next) => {
    c.set("userId", "u-test");
    c.set("deviceId", "d-test");
    await next();
  });
  app.route("/extract", extractRoutes);
  return {
    request: (path: string, init: RequestInit) => app.request(path, init, envOverrides),
  };
}

const OCR = ["THE GROUNDS", "28/05/2026", "Flat White 9.00", "Big Brekkie 24.00", "TOTAL 33.00"].join(
  "\n",
);

describe("POST /extract (stub gate)", () => {
  it("returns the deterministic stub when DEEPSEEK_API_KEY is empty", async () => {
    const app = appWith({ DEEPSEEK_API_KEY: "" });
    const res = await app.request("/extract", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ ocrText: OCR, source: "scan", capturedAt: "2026-05-30" }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;

    // §9 response shape.
    expect(typeof body.requestId).toBe("string");
    expect(body.receipt.currencyCode).toBe("AUD");
    expect(body.receipt.merchant).toBe("THE GROUNDS");
    expect(body.receipt.date).toBe("2026-05-28");
    expect(body.receipt.total).toBe(33.0);
    expect(body.receipt.category).toBe("office"); // heuristic stub
    expect(body.receipt.deductible).toBe(100);
    expect(body.receipt.gst).toBe(3.0); // 33/11
    expect(body.receipt.needsReview).toBe(false); // stub forces false
    expect(body.receipt.confidence).toBe(0.9); // stub fixed
    expect(body.meta.stub).toBe(true);
    expect(body.meta.source).toBe("scan");
    expect(typeof body.meta.latencyMs).toBe("number");
    expect(body.meta.attempts).toBe(0);
  });

  it("engages the stub when E2E_EXTRACT_MODE === '1' even with a key set", async () => {
    const app = appWith({ DEEPSEEK_API_KEY: "sk-real", E2E_EXTRACT_MODE: "1" });
    const res = await app.request("/extract", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ ocrText: OCR, source: "email_in" }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;
    expect(body.meta.stub).toBe(true);
    expect(body.meta.source).toBe("email_in");
  });

  it("echoes a provided requestId", async () => {
    const app = appWith({ DEEPSEEK_API_KEY: "" });
    const res = await app.request("/extract", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ ocrText: OCR, source: "scan", requestId: "client-123" }),
    });
    const body = (await res.json()) as any;
    expect(body.requestId).toBe("client-123");
  });

  it("rejects an empty ocrText with 400 VALIDATION_FAILED", async () => {
    const app = appWith({ DEEPSEEK_API_KEY: "" });
    const res = await app.request("/extract", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ ocrText: "", source: "scan" }),
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as any;
    expect(body.error.code).toBe("VALIDATION_FAILED");
  });

  it("defaults the date to today when no capturedAt and OCR has no date", async () => {
    const app = appWith({ DEEPSEEK_API_KEY: "" });
    const res = await app.request("/extract", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ ocrText: "WIDGET CO\nTOTAL 10.00", source: "scan" }),
    });
    const body = (await res.json()) as any;
    expect(body.receipt.date).toMatch(/^\d{4}-\d{2}-\d{2}$/);
  });
});
