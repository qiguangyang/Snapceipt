import { env, SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { nowMs } from "../src/lib/time";
import { issueSession } from "../src/lib/sessions";

// test/helpers/seed.ts does not exist — the seed is inlined here following the
// pattern in test/account-delete.test.ts: insert a users row + a devices row,
// then mint a bearer via issueSession.
async function seedUserWithSession(): Promise<{ userId: string; deviceId: string; bearer: string }> {
  const userId = crypto.randomUUID();
  const deviceId = crypto.randomUUID();
  const t = nowMs();
  await env.DB.prepare(
    `INSERT INTO users (id, email, email_verified, plan, created_at, updated_at) VALUES (?, ?, 1, 'free', ?, ?)`,
  ).bind(userId, `${userId}@e.com`, t, t).run();
  await env.DB.prepare(
    `INSERT INTO devices (id, user_id, platform, push_enabled, created_at, updated_at) VALUES (?, ?, 'ios', 1, ?, ?)`,
  ).bind(deviceId, userId, t, t).run();
  const { accessToken } = await issueSession(env.DB, {
    userId,
    deviceId,
    signingKey: env.JWT_SIGNING_KEY,
  });
  return { userId, deviceId, bearer: accessToken };
}

describe("account delete purges attest_keys", () => {
  it("removes the user's device attest_keys rows", async () => {
    const { userId, deviceId, bearer } = await seedUserWithSession();
    await env.DB.prepare(
      "INSERT INTO attest_keys (key_id, device_id, public_key, sign_count, aaguid, created_at) VALUES (?,?,?,?,?,?)",
    ).bind("k_" + userId, deviceId, new Uint8Array([1, 2, 3]), 0, "appattest", Date.now()).run();

    const res = await SELF.fetch("https://x/account", {
      method: "DELETE",
      headers: { authorization: `Bearer ${bearer}` },
    });
    expect(res.status).toBe(200);

    const left = await env.DB.prepare("SELECT COUNT(*) AS n FROM attest_keys WHERE device_id = ?")
      .bind(deviceId).first<{ n: number }>();
    expect(left?.n).toBe(0);
  });
});
