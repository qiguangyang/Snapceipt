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
    .bind(userId, "qh@example.com", "QH User", now, now)
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

describe("PUT /devices/me — quiet hours + timezone", () => {
  it("persists quietHoursStartMin/quietHoursEndMin/timezone alongside apnsToken", async () => {
    const { accessToken, deviceId } = await seedAuthedDevice();

    const res = await SELF.fetch("https://x/devices/me", {
      method: "PUT",
      headers: {
        authorization: `Bearer ${accessToken}`,
        "content-type": "application/json",
        "x-device-id": deviceId,
      },
      body: JSON.stringify({
        apnsToken: "apns-hex-1",
        quietHoursStartMin: 1320,
        quietHoursEndMin: 420,
        timezone: "Australia/Sydney",
      }),
    });
    expect(res.status).toBe(200);

    const row = await env.DB.prepare(
      `SELECT apns_token, quiet_hours_start_min, quiet_hours_end_min, timezone FROM devices WHERE id = ?`,
    )
      .bind(deviceId)
      .first<{
        apns_token: string;
        quiet_hours_start_min: number;
        quiet_hours_end_min: number;
        timezone: string;
      }>();
    expect(row?.apns_token).toBe("apns-hex-1");
    expect(row?.quiet_hours_start_min).toBe(1320);
    expect(row?.quiet_hours_end_min).toBe(420);
    expect(row?.timezone).toBe("Australia/Sydney");
  });

  it("a partial update does not clobber previously-stored quiet hours", async () => {
    const { accessToken, deviceId } = await seedAuthedDevice();
    const put = (body: unknown) =>
      SELF.fetch("https://x/devices/me", {
        method: "PUT",
        headers: {
          authorization: `Bearer ${accessToken}`,
          "content-type": "application/json",
          "x-device-id": deviceId,
        },
        body: JSON.stringify(body),
      });

    await put({ quietHoursStartMin: 1320, quietHoursEndMin: 420, timezone: "Australia/Perth" });
    // A later call that only updates the token must keep the quiet hours.
    const res = await put({ apnsToken: "tok-2" });
    expect(res.status).toBe(200);

    const row = await env.DB.prepare(
      `SELECT apns_token, quiet_hours_start_min, quiet_hours_end_min, timezone FROM devices WHERE id = ?`,
    )
      .bind(deviceId)
      .first<{
        apns_token: string;
        quiet_hours_start_min: number;
        quiet_hours_end_min: number;
        timezone: string;
      }>();
    expect(row?.apns_token).toBe("tok-2");
    expect(row?.quiet_hours_start_min).toBe(1320);
    expect(row?.quiet_hours_end_min).toBe(420);
    expect(row?.timezone).toBe("Australia/Perth");
  });

  it("rejects an out-of-range quietHoursStartMin with 400 VALIDATION_FAILED", async () => {
    const { accessToken, deviceId } = await seedAuthedDevice();
    const res = await SELF.fetch("https://x/devices/me", {
      method: "PUT",
      headers: {
        authorization: `Bearer ${accessToken}`,
        "content-type": "application/json",
        "x-device-id": deviceId,
      },
      body: JSON.stringify({ quietHoursStartMin: 5000 }),
    });
    expect(res.status).toBe(400);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe("VALIDATION_FAILED");
  });
});
