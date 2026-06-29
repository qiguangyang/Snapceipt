import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { issueSession } from "../src/lib/sessions";

// Seed a user + device + active session directly in D1, returning the raw refresh token.
// issueSession mints the access token (Canonical Contracts), so it needs the signing key.
async function seedSession() {
  const userId = uuidv7();
  const deviceId = uuidv7();
  const now = nowMs();
  await env.DB.prepare(
    `INSERT INTO users (id, email, email_verified, display_name, plan, created_at, updated_at)
     VALUES (?, ?, 1, ?, 'free', ?, ?)`,
  )
    .bind(userId, "maya@example.com", "Maya Reyes", now, now)
    .run();
  await env.DB.prepare(
    `INSERT INTO devices (id, user_id, platform, push_enabled, created_at, updated_at)
     VALUES (?, ?, 'ios', 1, ?, ?)`,
  )
    .bind(deviceId, userId, now, now)
    .run();
  const issued = await issueSession(env.DB, {
    userId,
    deviceId,
    signingKey: env.JWT_SIGNING_KEY,
  });
  return { userId, deviceId, ...issued };
}

beforeEach(async () => {
  // Per-test-file storage is isolated; clear rows that tests insert so counts are deterministic.
  await env.DB.exec("DELETE FROM sessions");
  await env.DB.exec("DELETE FROM devices");
  await env.DB.exec("DELETE FROM users");
});

describe("POST /auth/refresh", () => {
  it("rotates the refresh token and mints a new access token (happy path)", async () => {
    const { refreshToken } = await seedSession();

    const res = await SELF.fetch("https://x/auth/refresh", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ refreshToken }),
    });

    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      accessToken: string;
      refreshToken: string;
      expiresIn: number;
      user: { id: string; email: string; displayName: string };
    };
    expect(body.expiresIn).toBe(600);
    expect(body.accessToken).toMatch(/^[\w-]+\.[\w-]+\.[\w-]+$/);
    // Rotated: new refresh token differs from the one we sent.
    expect(body.refreshToken).not.toBe(refreshToken);
    expect(body.user.email).toBe("maya@example.com");
    expect(body.user.displayName).toBe("Maya Reyes");

    // The new token works on a subsequent refresh.
    const again = await SELF.fetch("https://x/auth/refresh", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ refreshToken: body.refreshToken }),
    });
    expect(again.status).toBe(200);
  });

  it("revokes the whole family and returns 401 AUTH_SESSION_REVOKED when an already-rotated token is reused", async () => {
    const { refreshToken: original } = await seedSession();

    // First refresh rotates `original` -> `next`.
    const first = await SELF.fetch("https://x/auth/refresh", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ refreshToken: original }),
    });
    expect(first.status).toBe(200);
    const { refreshToken: next } = (await first.json()) as { refreshToken: string };

    // Reuse the now-rotated `original` -> reuse detected.
    const reuse = await SELF.fetch("https://x/auth/refresh", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ refreshToken: original }),
    });
    expect(reuse.status).toBe(401);
    const reuseBody = (await reuse.json()) as { error: { code: string; requestId: string } };
    expect(reuseBody.error.code).toBe("AUTH_SESSION_REVOKED");
    expect(reuseBody.error.requestId).toBeTruthy();

    // The legitimate rotated token `next` is now also dead (whole family revoked).
    const afterReuse = await SELF.fetch("https://x/auth/refresh", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ refreshToken: next }),
    });
    expect(afterReuse.status).toBe(401);
    expect(((await afterReuse.json()) as { error: { code: string } }).error.code).toBe(
      "AUTH_SESSION_REVOKED",
    );
  });

  it("returns 401 AUTH_INVALID_TOKEN for an unknown refresh token", async () => {
    const res = await SELF.fetch("https://x/auth/refresh", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ refreshToken: "not-a-real-token" }),
    });
    expect(res.status).toBe(401);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe(
      "AUTH_INVALID_TOKEN",
    );
  });
});

describe("POST /auth/signout", () => {
  it("revokes the current session so its refresh token no longer works", async () => {
    const { accessToken, refreshToken } = await seedSession();

    const out = await SELF.fetch("https://x/auth/signout", {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}` },
    });
    expect(out.status).toBe(200);
    expect(await out.json()).toEqual({ ok: true });

    // Refresh on a signed-out session is rejected.
    const refresh = await SELF.fetch("https://x/auth/refresh", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ refreshToken }),
    });
    expect(refresh.status).toBe(401);
    expect(((await refresh.json()) as { error: { code: string } }).error.code).toBe(
      "AUTH_SESSION_REVOKED",
    );
  });

  it("rejects signout without a bearer token", async () => {
    const res = await SELF.fetch("https://x/auth/signout", { method: "POST" });
    expect(res.status).toBe(401);
  });
});

describe("GET /auth/me", () => {
  it("returns the current user and their active devices", async () => {
    const { accessToken, userId, deviceId } = await seedSession();

    const res = await SELF.fetch("https://x/auth/me", {
      headers: { authorization: `Bearer ${accessToken}` },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      user: { id: string; email: string; displayName: string };
      devices: Array<{ id: string }>;
    };
    expect(body.user.id).toBe(userId);
    expect(body.user.email).toBe("maya@example.com");
    expect(body.devices).toHaveLength(1);
    expect(body.devices[0]?.id).toBe(deviceId);
  });

  it("rejects /auth/me without a bearer token", async () => {
    const res = await SELF.fetch("https://x/auth/me");
    expect(res.status).toBe(401);
  });
});
