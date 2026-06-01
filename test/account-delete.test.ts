import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { issueSession } from "../src/lib/sessions";

async function seedRichUser(): Promise<{ userId: string; bearer: string; r2Key: string }> {
  const userId = uuidv7();
  const deviceId = uuidv7();
  const profileId = uuidv7();
  const txnId = uuidv7();
  const t = nowMs();
  await env.DB.prepare(`INSERT INTO users (id, email, email_verified, plan, created_at, updated_at) VALUES (?, ?, 1, 'free', ?, ?)`).bind(userId, `${userId}@e.com`, t, t).run();
  await env.DB.prepare(`INSERT INTO devices (id, user_id, platform, push_enabled, created_at, updated_at) VALUES (?, ?, 'ios', 1, ?, ?)`).bind(deviceId, userId, t, t).run();
  await env.DB.prepare(`INSERT INTO profiles (id, user_id, name, type, accent_1, accent_2, accent_3, created_at, updated_at) VALUES (?, ?, 'Biz', 'business', '#0','#1','#2', ?, ?)`).bind(profileId, userId, t, t).run();
  await env.DB.prepare(`INSERT INTO transactions (id, user_id, profile_id, merchant, cat_key, amount_cents, currency, txn_date, mode, is_ai, source, created_at, updated_at, rev) VALUES (?, ?, ?, 'X', 'office', -100, 'AUD', '2026-06-01', 'business', 0, 'manual', ?, ?, 0)`).bind(txnId, userId, profileId, t, t).run();
  const r2Key = `u/${userId}/x.jpg`;
  await env.RECEIPTS.put(r2Key, new TextEncoder().encode("img"));
  const { accessToken } = await issueSession(env.DB, { userId, deviceId, signingKey: env.JWT_SIGNING_KEY });
  return { userId, bearer: `Bearer ${accessToken}`, r2Key };
}

beforeEach(async () => {
  for (const t of ["transactions", "profiles", "sessions", "devices", "users"]) {
    await env.DB.exec(`DELETE FROM ${t}`);
  }
});

describe("DELETE /account", () => {
  it("purges all D1 rows + R2 objects for the user", async () => {
    const { userId, bearer, r2Key } = await seedRichUser();
    const res = await SELF.fetch("https://x/account", { method: "DELETE", headers: { authorization: bearer } });
    expect(res.status).toBe(200);

    for (const table of ["users", "profiles", "transactions", "devices"]) {
      const row = await env.DB.prepare(`SELECT COUNT(*) c FROM ${table} WHERE user_id = ?`).bind(userId).first<{ c: number }>();
      expect(row!.c).toBe(0);
    }
    const obj = await env.RECEIPTS.get(r2Key);
    expect(obj).toBeNull();
  });

  it("does not touch another user's data", async () => {
    const a = await seedRichUser();
    const b = await seedRichUser();
    await SELF.fetch("https://x/account", { method: "DELETE", headers: { authorization: a.bearer } });
    const bRows = await env.DB.prepare("SELECT COUNT(*) c FROM transactions WHERE user_id = ?").bind(b.userId).first<{ c: number }>();
    expect(bRows!.c).toBe(1);
  });
});
