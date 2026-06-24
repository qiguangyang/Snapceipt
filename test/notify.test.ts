import { describe, it, expect, vi, beforeEach } from "vitest";
import { env } from "cloudflare:test";
import * as apns from "../src/lib/apns";
import { notifyEmailInReceipt } from "../src/email/notify";

const T = 1_700_000_000_000;
async function seedUserWithDevice(userId: string, token: string | null, pushEnabled = 1) {
  await env.DB.prepare(`INSERT INTO users (id, plan, created_at, updated_at) VALUES (?, 'pro', ?, ?)`).bind(userId, T, T).run();
  await env.DB.prepare(
    `INSERT INTO devices (id, user_id, platform, apns_token, push_enabled, created_at, updated_at)
     VALUES (?, ?, 'ios', ?, ?, ?, ?)`,
  ).bind(`dev_${userId}`, userId, token, pushEnabled, T, T).run();
}

describe("notifyEmailInReceipt", () => {
  beforeEach(() => vi.restoreAllMocks());

  it("pushes the created payload to an enabled device", async () => {
    const spy = vi.spyOn(apns, "sendPush").mockResolvedValue({ stub: false, status: 200 });
    await seedUserWithDevice("u_created", "tok_created");
    await notifyEmailInReceipt(env, "u_created", "txn1", "Woolworths", "done", T);
    expect(spy).toHaveBeenCalledTimes(1);
    const [, token, payload] = spy.mock.calls[0];
    expect(token).toBe("tok_created");
    expect(payload.aps.alert.title).toBe("New receipt");
    expect(payload.aps.alert.body).toBe("From Woolworths — tap to review.");
    expect(payload.type).toBe("email_in");
    expect(payload.transactionId).toBe("txn1");
    expect(payload.deepLink).toBe("snapceipt://receipt/txn1");
  });

  it("uses the failed copy and the no-merchant fallback", async () => {
    const spy = vi.spyOn(apns, "sendPush").mockResolvedValue({ stub: false, status: 200 });
    await seedUserWithDevice("u_failed", "tok_failed");
    await notifyEmailInReceipt(env, "u_failed", "txn2", "", "failed", T);
    const p = spy.mock.calls[0][2];
    expect(p.aps.alert.title).toBe("Receipt received");
    expect(p.aps.alert.body).toBe("Couldn't read it automatically — tap to review.");

    const spy2 = vi.spyOn(apns, "sendPush").mockResolvedValue({ stub: false, status: 200 });
    await env.DB.prepare(`UPDATE devices SET apns_token = 'tok_nomerch' WHERE user_id = 'u_failed'`).run();
    await notifyEmailInReceipt(env, "u_failed", "txn3", "", "done", T);
    expect(spy2.mock.calls.at(-1)![2].aps.alert.body).toBe("New emailed receipt — tap to review.");
  });

  it("skips a push-disabled device and a null-token device", async () => {
    const spy = vi.spyOn(apns, "sendPush").mockResolvedValue({ stub: false, status: 200 });
    await seedUserWithDevice("u_off", "tok_off", 0);
    await notifyEmailInReceipt(env, "u_off", "txn4", "X", "done", T);
    await seedUserWithDevice("u_nulltok", null);
    await notifyEmailInReceipt(env, "u_nulltok", "txn5", "X", "done", T);
    expect(spy).not.toHaveBeenCalled();
  });

  it("nulls the token on a 410 and never throws on a sendPush error", async () => {
    vi.spyOn(apns, "sendPush").mockResolvedValue({ stub: false, status: 410 });
    await seedUserWithDevice("u_410", "tok_410");
    await notifyEmailInReceipt(env, "u_410", "txn6", "X", "done", T);
    const row = await env.DB.prepare(`SELECT apns_token FROM devices WHERE user_id = 'u_410'`).first<{ apns_token: string | null }>();
    expect(row?.apns_token).toBeNull();

    vi.spyOn(apns, "sendPush").mockRejectedValue(new Error("boom"));
    await seedUserWithDevice("u_throw", "tok_throw");
    await expect(notifyEmailInReceipt(env, "u_throw", "txn7", "X", "done", T)).resolves.toBeUndefined();
  });
});
