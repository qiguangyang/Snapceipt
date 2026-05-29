import { SELF } from "cloudflare:test";
import { describe, it, expect } from "vitest";
import { uuidv7 } from "../src/lib/ids";
import { nowMs, serverStamp } from "../src/lib/time";
import { ApiError, ERROR, toEnvelope } from "../src/lib/errors";

describe("uuidv7()", () => {
  it("produces RFC-shaped v7 UUIDs (version 7, variant 10xx)", () => {
    const id = uuidv7();
    expect(id).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
    );
  });

  it("generates unique ids across a large batch", () => {
    const seen = new Set<string>();
    for (let i = 0; i < 10000; i++) seen.add(uuidv7());
    expect(seen.size).toBe(10000);
  });

  it("is monotonic / lexicographically sortable in generation order", () => {
    const ids = Array.from({ length: 5000 }, () => uuidv7());
    const sorted = [...ids].sort();
    expect(sorted).toEqual(ids);
  });
});

describe("time helpers", () => {
  it("nowMs() returns an integer epoch-ms close to Date.now()", () => {
    const t = nowMs();
    expect(Number.isInteger(t)).toBe(true);
    expect(Math.abs(t - Date.now())).toBeLessThan(1000);
  });

  it("serverStamp() returns a fresh monotonic-ish epoch-ms each call", () => {
    const a = serverStamp();
    const b = serverStamp();
    expect(Number.isInteger(a)).toBe(true);
    expect(b).toBeGreaterThanOrEqual(a);
  });

  it("serverStamp() is STRICTLY monotonic across rapid successive calls", () => {
    // Sync LWW + the keyset cursor depend on strictly-increasing stamps:
    // two calls in the same ms must still yield prev+1, never equal.
    const stamps = Array.from({ length: 1000 }, () => serverStamp());
    for (let i = 1; i < stamps.length; i++) {
      expect(stamps[i]).toBeGreaterThan(stamps[i - 1]!);
    }
  });
});

describe("ApiError + ERROR map + toEnvelope()", () => {
  it("maps each error code to its documented HTTP status", () => {
    expect(ERROR.AUTH_INVALID_TOKEN).toBe(401);
    expect(ERROR.AUTH_SESSION_REVOKED).toBe(401);
    expect(ERROR.VALIDATION_FAILED).toBe(400);
    expect(ERROR.NOT_FOUND).toBe(404);
    expect(ERROR.FORBIDDEN).toBe(403);
    expect(ERROR.RATE_LIMITED).toBe(429);
    expect(ERROR.CONFLICT).toBe(409);
    expect(ERROR.NOT_IMPLEMENTED).toBe(501);
    expect(ERROR.INTERNAL).toBe(500);
  });

  it("ApiError carries code, derived status, message and optional details", () => {
    const e = new ApiError("VALIDATION_FAILED", "bad body", { field: "email" });
    expect(e).toBeInstanceOf(Error);
    expect(e.code).toBe("VALIDATION_FAILED");
    expect(e.status).toBe(400);
    expect(e.message).toBe("bad body");
    expect(e.details).toEqual({ field: "email" });
  });

  it("toEnvelope() serializes an ApiError into the uniform envelope shape", () => {
    const e = new ApiError("NOT_FOUND", "missing", { id: "x" });
    expect(toEnvelope(e, "req-123")).toEqual({
      error: {
        code: "NOT_FOUND",
        message: "missing",
        details: { id: "x" },
        requestId: "req-123",
      },
    });
  });

  it("toEnvelope() coerces an unknown error to INTERNAL with no details leak", () => {
    const env2 = toEnvelope(new Error("boom"), "req-9");
    expect(env2).toEqual({
      error: { code: "INTERNAL", message: "Internal Server Error", requestId: "req-9" },
    });
  });
});

describe("HTTP: error middleware produces the envelope + X-Request-Id", () => {
  // Asserted against REAL routes (no test-only /__throw scaffold): the shared
  // /banks placeholder throws ApiError("NOT_IMPLEMENTED") so it exercises the
  // ApiError -> status + envelope + X-Request-Id path end-to-end.
  it("a route that throws ApiError (/banks -> 501) returns the matching status + envelope", async () => {
    const res = await SELF.fetch("https://example.com/banks");
    expect(res.status).toBe(501);
    const reqId = res.headers.get("X-Request-Id");
    expect(reqId).toBeTruthy();
    const body = (await res.json()) as {
      error: { code: string; message: string; requestId: string };
    };
    expect(body.error.code).toBe("NOT_IMPLEMENTED");
    expect(body.error.message).toBeTruthy();
    // The envelope's requestId matches the X-Request-Id response header.
    expect(body.error.requestId).toBe(reqId);
  });

  it("an unknown path under a public prefix returns 404", async () => {
    // The app is protected-by-default (authMiddleware 401s any non-public path),
    // so to reach Hono's notFound handler we hit an unknown path under a PUBLIC
    // prefix (/auth/*): auth lets it through, no route matches -> 404.
    const res = await SELF.fetch("https://example.com/auth/no-such-route");
    expect(res.status).toBe(404);
  });
});
