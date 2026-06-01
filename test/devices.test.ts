import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { issueSession } from "../src/lib/sessions";

async function seedAuthedDevice() {
  const userId = uuidv7();
  const deviceId = uuidv7();
  const now = nowMs();
  await env.DB.prepare(
    `INSERT INTO users (id, email, email_verified, display_name, plan, created_at, updated_at)
     VALUES (?, ?, 1, ?, 'free', ?, ?)`,
  )
    .bind(userId, "dev@example.com", "Dev User", now, now)
    .run();
  await env.DB.prepare(
    `INSERT INTO devices (id, user_id, platform, push_enabled, created_at, updated_at)
     VALUES (?, ?, 'ios', 1, ?, ?)`,
  )
    .bind(deviceId, userId, now, now)
    .run();
  const { accessToken } = await issueSession(env.DB, {
    userId,
    deviceId,
    signingKey: env.JWT_SIGNING_KEY,
  });
  return { userId, deviceId, accessToken };
}

beforeEach(async () => {
  await env.DB.exec("DELETE FROM sessions");
  await env.DB.exec("DELETE FROM devices");
  await env.DB.exec("DELETE FROM users");
});

describe("PUT /devices/me", () => {
  it("upserts apnsToken/appVersion/osVersion for the device named by X-Device-Id", async () => {
    const { accessToken, deviceId } = await seedAuthedDevice();

    const res = await SELF.fetch("https://x/devices/me", {
      method: "PUT",
      headers: {
        authorization: `Bearer ${accessToken}`,
        "content-type": "application/json",
        "x-device-id": deviceId,
      },
      body: JSON.stringify({
        apnsToken: "abc123apns",
        appVersion: "1.0.0",
        osVersion: "iOS 18.2",
        model: "iPhone16,2",
      }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { id: string; pushEnabled: boolean };
    expect(body.id).toBe(deviceId);

    const row = await env.DB.prepare(
      `SELECT apns_token, os_version, model FROM devices WHERE id = ?`,
    )
      .bind(deviceId)
      .first<{ apns_token: string; os_version: string; model: string }>();
    expect(row?.apns_token).toBe("abc123apns");
    expect(row?.os_version).toBe("iOS 18.2");
    expect(row?.model).toBe("iPhone16,2");
  });

  it("creates the device row if X-Device-Id is new for this user", async () => {
    const { accessToken } = await seedAuthedDevice();
    const newDeviceId = uuidv7();

    const res = await SELF.fetch("https://x/devices/me", {
      method: "PUT",
      headers: {
        authorization: `Bearer ${accessToken}`,
        "content-type": "application/json",
        "x-device-id": newDeviceId,
      },
      body: JSON.stringify({ apnsToken: "tok2", osVersion: "iOS 18.1" }),
    });
    expect(res.status).toBe(200);

    const row = await env.DB.prepare(`SELECT id, apns_token FROM devices WHERE id = ?`)
      .bind(newDeviceId)
      .first<{ id: string; apns_token: string }>();
    expect(row?.id).toBe(newDeviceId);
    expect(row?.apns_token).toBe("tok2");
  });

  it("requires the X-Device-Id header", async () => {
    const { accessToken } = await seedAuthedDevice();
    const res = await SELF.fetch("https://x/devices/me", {
      method: "PUT",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
      body: JSON.stringify({ apnsToken: "x" }),
    });
    expect(res.status).toBe(400);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe(
      "VALIDATION_FAILED",
    );
  });

  it("rejects PUT /devices/me without a bearer token", async () => {
    const res = await SELF.fetch("https://x/devices/me", {
      method: "PUT",
      headers: { "content-type": "application/json", "x-device-id": uuidv7() },
      body: JSON.stringify({ apnsToken: "x" }),
    });
    expect(res.status).toBe(401);
  });
});

describe("DELETE /devices/:id", () => {
  it("tombstones the device and revokes its session family", async () => {
    const { accessToken, userId, deviceId } = await seedAuthedDevice();
    // A second device + session so we can prove only the targeted family dies.
    const otherDeviceId = uuidv7();
    const now = nowMs();
    await env.DB.prepare(
      `INSERT INTO devices (id, user_id, platform, push_enabled, created_at, updated_at)
       VALUES (?, ?, 'ios', 1, ?, ?)`,
    )
      .bind(otherDeviceId, userId, now, now)
      .run();
    const other = await issueSession(env.DB, {
      userId,
      deviceId: otherDeviceId,
      signingKey: env.JWT_SIGNING_KEY,
    });

    const res = await SELF.fetch(`https://x/devices/${deviceId}`, {
      method: "DELETE",
      headers: { authorization: `Bearer ${accessToken}` },
    });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true });

    // The deleted device is tombstoned.
    const gone = await env.DB.prepare(`SELECT deleted_at FROM devices WHERE id = ?`)
      .bind(deviceId)
      .first<{ deleted_at: number | null }>();
    expect(gone?.deleted_at).not.toBeNull();

    // Its sessions are revoked.
    const revoked = await env.DB.prepare(
      `SELECT COUNT(*) AS n FROM sessions WHERE device_id = ? AND revoked_at IS NULL`,
    )
      .bind(deviceId)
      .first<{ n: number }>();
    expect(revoked?.n).toBe(0);

    // The OTHER device's session still works.
    const stillGood = await SELF.fetch("https://x/auth/refresh", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ refreshToken: other.refreshToken }),
    });
    expect(stillGood.status).toBe(200);
  });

  it("returns 404 when deleting a device that is not the authed user's", async () => {
    const { accessToken } = await seedAuthedDevice();
    // A device owned by a different user.
    const otherUser = uuidv7();
    const foreignDevice = uuidv7();
    const now = nowMs();
    await env.DB.prepare(
      `INSERT INTO users (id, email, email_verified, display_name, plan, created_at, updated_at)
       VALUES (?, ?, 1, 'Other', 'free', ?, ?)`,
    )
      .bind(otherUser, "other@example.com", now, now)
      .run();
    await env.DB.prepare(
      `INSERT INTO devices (id, user_id, platform, push_enabled, created_at, updated_at)
       VALUES (?, ?, 'ios', 1, ?, ?)`,
    )
      .bind(foreignDevice, otherUser, now, now)
      .run();

    const res = await SELF.fetch(`https://x/devices/${foreignDevice}`, {
      method: "DELETE",
      headers: { authorization: `Bearer ${accessToken}` },
    });
    expect(res.status).toBe(404);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe("NOT_FOUND");
  });
});
