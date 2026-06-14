import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { issueSession } from "../src/lib/sessions";

async function seedAuthed(): Promise<{ bearer: string; userId: string; deviceId: string }> {
  const userId = uuidv7();
  const deviceId = uuidv7();
  const t = nowMs();
  await env.DB.prepare(
    `INSERT INTO users (id, email, email_verified, plan, created_at, updated_at) VALUES (?, ?, 1, 'free', ?, ?)`,
  ).bind(userId, `${userId}@e.com`, t, t).run();
  await env.DB.prepare(
    `INSERT INTO devices (id, user_id, platform, push_enabled, created_at, updated_at) VALUES (?, ?, 'ios', 1, ?, ?)`,
  ).bind(deviceId, userId, t, t).run();
  const { accessToken } = await issueSession(env.DB, { userId, deviceId, signingKey: env.JWT_SIGNING_KEY });
  return { bearer: `Bearer ${accessToken}`, userId, deviceId };
}

const body = {
  kind: "crash",
  appVersion: "0.1.0",
  osVersion: "iOS 18.5",
  deviceModel: "iPhone16,2",
  occurredAt: 1_718_400_000_000,
  payload: { signal: 11, terminationReason: "Namespace SIGNAL, Code 11" },
};

beforeEach(async () => {
  await env.DB.exec("DELETE FROM crash_reports");
  await env.DB.exec("DELETE FROM sessions");
  await env.DB.exec("DELETE FROM devices");
  await env.DB.exec("DELETE FROM users");
});

describe("POST /crash-reports", () => {
  it("stores a diagnostic scoped to the authed user + device", async () => {
    const { bearer, userId, deviceId } = await seedAuthed();
    const res = await SELF.fetch("https://x/crash-reports", {
      method: "POST",
      headers: { authorization: bearer, "content-type": "application/json" },
      body: JSON.stringify(body),
    });
    expect(res.status).toBe(201);
    const out = (await res.json()) as { id: string };
    expect(out.id).toMatch(/^[0-9a-f-]{36}$/);

    const row = await env.DB.prepare(
      "SELECT user_id, device_id, kind, app_version, payload FROM crash_reports WHERE id = ?",
    ).bind(out.id).first<{ user_id: string; device_id: string; kind: string; app_version: string; payload: string }>();
    expect(row?.user_id).toBe(userId);
    expect(row?.device_id).toBe(deviceId);
    expect(row?.kind).toBe("crash");
    expect(row?.app_version).toBe("0.1.0");
    expect(JSON.parse(row!.payload).signal).toBe(11);
  });

  it("401s without a bearer token", async () => {
    const res = await SELF.fetch("https://x/crash-reports", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    });
    expect(res.status).toBe(401);
  });

  it("400s on a malformed body", async () => {
    const { bearer } = await seedAuthed();
    const res = await SELF.fetch("https://x/crash-reports", {
      method: "POST",
      headers: { authorization: bearer, "content-type": "application/json" },
      body: JSON.stringify({ kind: "crash" }),
    });
    expect(res.status).toBe(400);
    const env2 = (await res.json()) as { error: { code: string } };
    expect(env2.error.code).toBe("VALIDATION_FAILED");
  });
});
