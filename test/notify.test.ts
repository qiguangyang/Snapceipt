import { describe, it, expect, vi, beforeEach } from "vitest";
import { env } from "cloudflare:test";
import * as apns from "../src/lib/apns";
import { notifyEmailInBatch } from "../src/email/notify";

const T = 1_700_000_000_000;
async function seedUserWithDevice(userId: string, token: string | null, pushEnabled = 1) {
  await env.DB.prepare(`INSERT INTO users (id, plan, created_at, updated_at) VALUES (?, 'pro', ?, ?)`).bind(userId, T, T).run();
  await env.DB.prepare(
    `INSERT INTO devices (id, user_id, platform, apns_token, push_enabled, created_at, updated_at)
     VALUES (?, ?, 'ios', ?, ?, ?, ?)`,
  ).bind(`dev_${userId}`, userId, token, pushEnabled, T, T).run();
}

describe("notifyEmailInBatch", () => {
  beforeEach(() => vi.restoreAllMocks());

  it("pushes a single-receipt summary (no transactionId → tap opens the list)", async () => {
    const spy = vi.spyOn(apns, "sendPush").mockResolvedValue({ stub: false, status: 200 });
    await seedUserWithDevice("u_one", "tok_one");
    await notifyEmailInBatch(env, "u_one", 1, T);
    expect(spy).toHaveBeenCalledTimes(1);
    const [, token, payload] = spy.mock.calls[0]!;
    expect(token).toBe("tok_one");
    expect(payload.aps.alert.title).toBe("New receipt");
    expect(payload.aps.alert.body).toBe("1 receipt arrived — tap to review.");
    expect(payload.type).toBe("email_in");
    expect(payload.transactionId).toBeUndefined(); // no per-receipt deep-link for the summary
    expect(payload.deepLink).toBeUndefined();
  });

  it("pushes a plural summary for multiple receipts", async () => {
    const spy = vi.spyOn(apns, "sendPush").mockResolvedValue({ stub: false, status: 200 });
    await seedUserWithDevice("u_many", "tok_many");
    await notifyEmailInBatch(env, "u_many", 3, T);
    const p = spy.mock.calls[0]![2];
    expect(p.aps.alert.title).toBe("New receipts");
    expect(p.aps.alert.body).toBe("3 receipts arrived — tap to review.");
  });

  it("is a no-op when count is 0 (nothing created)", async () => {
    const spy = vi.spyOn(apns, "sendPush").mockResolvedValue({ stub: false, status: 200 });
    await seedUserWithDevice("u_zero", "tok_zero");
    await notifyEmailInBatch(env, "u_zero", 0, T);
    expect(spy).not.toHaveBeenCalled();
  });

  it("skips a push-disabled device and a null-token device", async () => {
    const spy = vi.spyOn(apns, "sendPush").mockResolvedValue({ stub: false, status: 200 });
    await seedUserWithDevice("u_off", "tok_off", 0);
    await notifyEmailInBatch(env, "u_off", 1, T);
    await seedUserWithDevice("u_nulltok", null);
    await notifyEmailInBatch(env, "u_nulltok", 1, T);
    expect(spy).not.toHaveBeenCalled();
  });

  it("nulls the token on a 410 and never throws on a sendPush error", async () => {
    vi.spyOn(apns, "sendPush").mockResolvedValue({ stub: false, status: 410 });
    await seedUserWithDevice("u_410", "tok_410");
    await notifyEmailInBatch(env, "u_410", 1, T);
    const row = await env.DB.prepare(`SELECT apns_token FROM devices WHERE user_id = 'u_410'`).first<{ apns_token: string | null }>();
    expect(row?.apns_token).toBeNull();

    vi.spyOn(apns, "sendPush").mockRejectedValue(new Error("boom"));
    await seedUserWithDevice("u_throw", "tok_throw");
    await expect(notifyEmailInBatch(env, "u_throw", 1, T)).resolves.toBeUndefined();
  });

  it("routes the push to the device's APNs environment (dev->development, null->production)", async () => {
    const spy = vi.spyOn(apns, "sendPush").mockResolvedValue({ stub: false, status: 200 });
    await seedUserWithDevice("u_dev", "tok_dev");
    await env.DB.prepare(`UPDATE devices SET apns_environment = 'development' WHERE user_id = 'u_dev'`).run();
    await notifyEmailInBatch(env, "u_dev", 1, T);
    expect(spy.mock.calls[0]![3]).toBe("development");

    const spy2 = vi.spyOn(apns, "sendPush").mockResolvedValue({ stub: false, status: 200 });
    await seedUserWithDevice("u_prod", "tok_prod"); // apns_environment NULL -> production
    await notifyEmailInBatch(env, "u_prod", 1, T);
    expect(spy2.mock.calls[0]![3]).toBe("production");
  });
});
