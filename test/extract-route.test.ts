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

// The body is now the RAW receipt IMAGE bytes; source/capturedAt/requestId ride as query params.
const IMAGE_BODY = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0, 16, 1, 2, 3, 4]).buffer;
const IMAGE_HEADERS = { "content-type": "image/jpeg" };

describe("POST /extract (stub gate)", () => {
  it("returns the deterministic stub when GEMINI_API_KEY is empty", async () => {
    const app = appWith({ GEMINI_API_KEY: "" });
    const res = await app.request("/extract?source=scan&capturedAt=2026-05-30", {
      method: "POST",
      headers: IMAGE_HEADERS,
      body: IMAGE_BODY,
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;

    // §9 response shape. The stub extracts STUB_OCR_TEXT (image bytes are not OCR'd).
    expect(typeof body.requestId).toBe("string");
    expect(body.receipt.currencyCode).toBe("AUD");
    expect(body.receipt.merchant).toBe("ACME HARDWARE PTY LTD");
    // No date in STUB_OCR_TEXT → falls back to capturedAt.
    expect(body.receipt.date).toBe("2026-05-30");
    expect(body.receipt.total).toBe(33.0);
    expect(body.receipt.category).toBe("office"); // heuristic stub
    expect(body.receipt.deductible).toBe(100);
    expect(body.receipt.gst).toBe(3.0); // printed GST line
    expect(body.receipt.needsReview).toBe(false); // stub forces false
    expect(body.receipt.confidence).toBe(0.9); // stub fixed
    expect(body.meta.stub).toBe(true);
    expect(body.meta.source).toBe("scan");
    expect(typeof body.meta.latencyMs).toBe("number");
    expect(body.meta.attempts).toBe(0);
  });

  it("engages the stub when E2E_EXTRACT_MODE === '1' even with a key set", async () => {
    const app = appWith({ GEMINI_API_KEY: "g-real", E2E_EXTRACT_MODE: "1" });
    const res = await app.request("/extract?source=email_in", {
      method: "POST",
      headers: IMAGE_HEADERS,
      body: IMAGE_BODY,
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;
    expect(body.meta.stub).toBe(true);
    expect(body.meta.source).toBe("email_in");
  });

  it("echoes a provided requestId (query param)", async () => {
    const app = appWith({ GEMINI_API_KEY: "" });
    const res = await app.request("/extract?source=scan&requestId=client-123", {
      method: "POST",
      headers: IMAGE_HEADERS,
      body: IMAGE_BODY,
    });
    const body = (await res.json()) as any;
    expect(body.requestId).toBe("client-123");
  });

  it("rejects an empty image body with 400 VALIDATION_FAILED", async () => {
    const app = appWith({ GEMINI_API_KEY: "" });
    const res = await app.request("/extract?source=scan", {
      method: "POST",
      headers: IMAGE_HEADERS,
      body: new Uint8Array([]).buffer,
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as any;
    expect(body.error.code).toBe("VALIDATION_FAILED");
  });

  it("rejects an over-cap image body (>6 MiB) with 400 VALIDATION_FAILED", async () => {
    const app = appWith({ GEMINI_API_KEY: "" });
    const res = await app.request("/extract?source=scan", {
      method: "POST",
      headers: IMAGE_HEADERS,
      body: new Uint8Array(6_291_457).buffer, // 6 MiB + 1
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as any;
    expect(body.error.code).toBe("VALIDATION_FAILED");
  });

  it("defaults the date to today when no capturedAt is supplied", async () => {
    const app = appWith({ GEMINI_API_KEY: "" });
    const res = await app.request("/extract?source=scan", {
      method: "POST",
      headers: IMAGE_HEADERS,
      body: IMAGE_BODY,
    });
    const body = (await res.json()) as any;
    expect(body.receipt.date).toMatch(/^\d{4}-\d{2}-\d{2}$/);
  });
});
