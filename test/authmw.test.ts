import { describe, it, expect } from "vitest";
import { env, SELF } from "cloudflare:test";
import { signAccess } from "../src/lib/jwt";

const KEY = env.JWT_SIGNING_KEY;

async function bearer(userId = "u-1", sid = "s-1", did = "d-1") {
  return `Bearer ${await signAccess(KEY, { userId, sessionId: sid, deviceId: did })}`;
}

describe("auth middleware", () => {
  it("allows the public /health route with no Authorization header", async () => {
    const res = await SELF.fetch("https://api.test/health");
    expect(res.status).toBe(200);
  });

  it("allows public /auth/* routes through without a token", async () => {
    // /auth/refresh exists (Task 6); without a body it should NOT be a 401 from auth mw.
    const res = await SELF.fetch("https://api.test/auth/refresh", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{}",
    });
    expect(res.status).not.toBe(401);
  });

  it("allows the public /banks route through without a token", async () => {
    // /banks is public (Canonical Contracts). It returns 501 NOT_IMPLEMENTED, never 401.
    const res = await SELF.fetch("https://api.test/banks");
    expect(res.status).not.toBe(401);
  });

  it("rejects a protected route with no bearer -> 401 AUTH_INVALID_TOKEN envelope", async () => {
    const res = await SELF.fetch("https://api.test/devices/me", { method: "PUT", body: "{}" });
    expect(res.status).toBe(401);
    const body = (await res.json()) as { error: { code: string; requestId: string } };
    expect(body.error.code).toBe("AUTH_INVALID_TOKEN");
    expect(body.error.requestId).toBeTruthy();
  });

  it("rejects a malformed/invalid bearer token -> 401", async () => {
    const res = await SELF.fetch("https://api.test/devices/me", {
      method: "PUT",
      headers: { Authorization: "Bearer not-a-real-jwt" },
      body: "{}",
    });
    expect(res.status).toBe(401);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe("AUTH_INVALID_TOKEN");
  });

  it("rejects a token signed with the wrong key -> 401", async () => {
    const token = await signAccess("some-other-key-not-the-server-key", {
      userId: "u-1",
      sessionId: "s-1",
      deviceId: "d-1",
    });
    const res = await SELF.fetch("https://api.test/devices/me", {
      method: "PUT",
      headers: { Authorization: `Bearer ${token}` },
      body: "{}",
    });
    expect(res.status).toBe(401);
  });

  it("accepts a valid bearer and exposes userId/deviceId on a probe route", async () => {
    const res = await SELF.fetch("https://api.test/__authprobe", {
      headers: { Authorization: await bearer("u-42", "s-9", "d-7") },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { userId: string; deviceId: string };
    expect(body.userId).toBe("u-42");
    expect(body.deviceId).toBe("d-7");
  });
});
