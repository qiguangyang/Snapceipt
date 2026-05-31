import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { issueSession } from "../src/lib/sessions";

async function seedSession() {
  const userId = uuidv7();
  const deviceId = uuidv7();
  const now = nowMs();
  await env.DB.prepare(
    `INSERT INTO users (id, email, email_verified, display_name, plan, created_at, updated_at)
     VALUES (?, ?, 1, 'Dev', 'free', ?, ?)`,
  ).bind(userId, `${userId}@example.com`, now, now).run();
  await env.DB.prepare(
    `INSERT INTO devices (id, user_id, platform, push_enabled, created_at, updated_at)
     VALUES (?, ?, 'ios', 1, ?, ?)`,
  ).bind(deviceId, userId, now, now).run();
  await env.DB.prepare(
    `INSERT INTO profiles (id,user_id,name,type,accent_1,accent_2,accent_3,created_at,updated_at)
     VALUES (?,?,'P','business','#0E7C72','#DCF0ED','#0A5950',?,?)`,
  ).bind(uuidv7(), userId, now, now).run();
  const { accessToken } = await issueSession(env.DB, { userId, deviceId, signingKey: env.JWT_SIGNING_KEY });
  return { userId, accessToken };
}

beforeEach(async () => {
  await env.DB.exec("DELETE FROM receipt_images");
  await env.DB.exec("DELETE FROM transactions");
  await env.DB.exec("DELETE FROM profiles");
  await env.DB.exec("DELETE FROM sessions");
  await env.DB.exec("DELETE FROM devices");
  await env.DB.exec("DELETE FROM users");
});

describe("/export (through the real app)", () => {
  it("requires auth (401 without a bearer token)", async () => {
    const res = await SELF.fetch("https://x/export", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ profileId: "p", format: "csv", from: "2026-05-01", to: "2026-05-31" }),
    });
    expect(res.status).toBe(401);
  });

  it("GET /export/dl/* is public (no auth) — a forged token is 403, not 401", async () => {
    const res = await SELF.fetch("https://x/export/dl/forged");
    expect(res.status).toBe(403);
  });

  it("rate-limits the export tier at 60/user/hr (the 61st request is 429)", async () => {
    const { accessToken } = await seedSession();
    const headers = { authorization: `Bearer ${accessToken}`, "content-type": "application/json" };
    // Use an unowned profileId so each request short-circuits at 403 (still
    // counts against the limiter, which runs BEFORE the handler).
    const body = JSON.stringify({ profileId: "nope", format: "csv", from: "2026-05-01", to: "2026-05-31" });
    let last = 200;
    for (let i = 0; i < 61; i++) {
      const res = await SELF.fetch("https://x/export", { method: "POST", headers, body });
      last = res.status;
    }
    expect(last).toBe(429);
  });
});
