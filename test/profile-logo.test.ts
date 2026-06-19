import { env, SELF, applyD1Migrations } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { issueSession } from "../src/lib/sessions";

declare module "cloudflare:test" {
  interface ProvidedEnv {
    TEST_MIGRATIONS: Parameters<typeof applyD1Migrations>[1];
  }
}

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

beforeEach(async () => {
  await env.DB.exec("DELETE FROM profiles");
  await env.DB.exec("DELETE FROM sessions");
  await env.DB.exec("DELETE FROM devices");
  await env.DB.exec("DELETE FROM users");
});

const BASE = "https://api.test";

async function seedAuthed() {
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
  const { accessToken } = await issueSession(env.DB, { userId, deviceId, signingKey: env.JWT_SIGNING_KEY });
  return { userId, accessToken };
}

async function seedProfile(userId: string) {
  const profileId = uuidv7();
  const now = nowMs();
  await env.DB.prepare(
    `INSERT INTO profiles (id,user_id,name,type,accent_1,accent_2,accent_3,created_at,updated_at)
     VALUES (?,?,'Acme','business','#0E7C72','#DCF0ED','#0A5950',?,?)`,
  ).bind(profileId, userId, now, now).run();
  return profileId;
}

const PNG = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]); // PNG magic

describe("POST /profile/logo", () => {
  it("stores the logo to R2 and sets logo_r2_key", async () => {
    const { userId, accessToken } = await seedAuthed();
    const profileId = await seedProfile(userId);

    const res = await SELF.fetch(`${BASE}/profile/logo?profileId=${profileId}`, {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "image/png" },
      body: PNG,
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;
    expect(body.ok).toBe(true);
    expect(body.logoR2Key).toBe(`${userId}/profiles/${profileId}/logo`);

    const row = await env.DB.prepare(`SELECT logo_r2_key FROM profiles WHERE id=?`).bind(profileId).first<any>();
    expect(row.logo_r2_key).toBe(`${userId}/profiles/${profileId}/logo`);

    const obj = await env.RECEIPTS.get(`${userId}/profiles/${profileId}/logo`);
    expect(obj).not.toBeNull();
    await obj!.arrayBuffer();
  });

  it("400 on a non-image content-type", async () => {
    const { userId, accessToken } = await seedAuthed();
    const profileId = await seedProfile(userId);
    const res = await SELF.fetch(`${BASE}/profile/logo?profileId=${profileId}`, {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "text/plain" },
      body: "x",
    });
    expect(res.status).toBe(400);
  });

  it("400 when profileId is missing", async () => {
    const { accessToken } = await seedAuthed();
    const res = await SELF.fetch(`${BASE}/profile/logo`, {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "image/png" },
      body: PNG,
    });
    expect(res.status).toBe(400);
  });

  it("404 for a profile owned by another user", async () => {
    const { accessToken } = await seedAuthed();
    const other = await seedAuthed();
    const profileId = await seedProfile(other.userId);
    const res = await SELF.fetch(`${BASE}/profile/logo?profileId=${profileId}`, {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "image/png" },
      body: PNG,
    });
    expect(res.status).toBe(404);
  });

  it("401 without a bearer token", async () => {
    const res = await SELF.fetch(`${BASE}/profile/logo?profileId=x`, {
      method: "POST",
      headers: { "content-type": "image/png" },
      body: PNG,
    });
    expect(res.status).toBe(401);
  });
});
