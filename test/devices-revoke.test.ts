import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { issueSession } from "../src/lib/sessions";

async function seed(): Promise<{ userId: string; deviceId: string; bearer: string }> {
  const userId = uuidv7();
  const deviceId = uuidv7();
  const t = nowMs();
  await env.DB.prepare(`INSERT INTO users (id, email, email_verified, plan, created_at, updated_at) VALUES (?, ?, 1, 'free', ?, ?)`).bind(userId, `${userId}@e.com`, t, t).run();
  await env.DB.prepare(`INSERT INTO devices (id, user_id, platform, push_enabled, created_at, updated_at) VALUES (?, ?, 'ios', 1, ?, ?)`).bind(deviceId, userId, t, t).run();
  const { accessToken } = await issueSession(env.DB, { userId, deviceId, signingKey: env.JWT_SIGNING_KEY });
  return { userId, deviceId, bearer: `Bearer ${accessToken}` };
}

beforeEach(async () => {
  await env.DB.exec("DELETE FROM sessions");
  await env.DB.exec("DELETE FROM devices");
  await env.DB.exec("DELETE FROM users");
});

describe("DELETE /devices/:id", () => {
  it("tombstones the device + revokes its sessions, dropping it from /auth/me", async () => {
    const { deviceId, bearer } = await seed();
    const del = await SELF.fetch(`https://x/devices/${deviceId}`, { method: "DELETE", headers: { authorization: bearer } });
    expect(del.status).toBe(200);
    const revoked = await env.DB.prepare("SELECT revoked_at FROM sessions WHERE device_id = ?").bind(deviceId).first<{ revoked_at: number | null }>();
    expect(revoked!.revoked_at).not.toBeNull();
    // DEVIATION from plan Step 1: the auth middleware (verifyBearer in
    // src/middleware/auth.ts) only verifies the JWT signature/expiry and does NOT
    // consult sessions.revoked_at, so the short-lived access token stays valid
    // after the session is revoked — GET /auth/me returns 200, not 401. The plan's
    // Step 2 anticipates this ("keep whichever assertion matches the actual
    // middleware behaviour"). Per §8.2 of the design contract the observable
    // effect is that the tombstoned device DROPS OUT of GET /auth/me, so we assert
    // exactly that.
    const me = await SELF.fetch("https://x/auth/me", { headers: { authorization: bearer } });
    expect(me.status).toBe(200);
    const body = (await me.json()) as { devices: Array<{ id: string }> };
    expect(body.devices.map((d) => d.id)).not.toContain(deviceId);
  });

  it("404s for another user's device", async () => {
    const { bearer } = await seed();
    const res = await SELF.fetch(`https://x/devices/${uuidv7()}`, { method: "DELETE", headers: { authorization: bearer } });
    expect(res.status).toBe(404);
  });
});
