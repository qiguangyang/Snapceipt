import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { makeSignedNotification } from "./helpers/appstore";

const ORIG_TXN = "1000000123456789";

async function seedSubscriber(plan = "free"): Promise<string> {
  const userId = uuidv7();
  const t = nowMs();
  await env.DB.prepare(
    `INSERT INTO users (id, email, email_verified, plan, original_transaction_id, created_at, updated_at)
     VALUES (?, ?, 1, ?, ?, ?, ?)`,
  ).bind(userId, `sub-${userId}@example.com`, plan, ORIG_TXN, t, t).run();
  return userId;
}

function post(signedPayload: string) {
  return SELF.fetch("https://api.test/appstore/notifications", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ signedPayload }),
  });
}

beforeEach(async () => {
  await env.DB.exec("DELETE FROM users");
});

describe("POST /appstore/notifications", () => {
  it("SUBSCRIBED flips the matching user to pro/active with expiry", async () => {
    const userId = await seedSubscriber("free");
    const res = await post(makeSignedNotification({
      notificationType: "SUBSCRIBED",
      originalTransactionId: ORIG_TXN,
      expiresDateMs: 9_999_999_999_000,
    }));
    expect(res.status).toBe(200);

    const row = await env.DB.prepare(
      "SELECT plan, subscription_status, subscription_expires_at FROM users WHERE id = ?",
    ).bind(userId).first<{ plan: string; subscription_status: string; subscription_expires_at: number }>();
    expect(row?.plan).toBe("pro");
    expect(row?.subscription_status).toBe("active");
    expect(row?.subscription_expires_at).toBe(9_999_999_999_000);
  });

  it("EXPIRED reverts a pro user to free/expired", async () => {
    const userId = await seedSubscriber("pro");
    const res = await post(makeSignedNotification({
      notificationType: "EXPIRED",
      originalTransactionId: ORIG_TXN,
    }));
    expect(res.status).toBe(200);
    const row = await env.DB.prepare("SELECT plan, subscription_status FROM users WHERE id = ?")
      .bind(userId).first<{ plan: string; subscription_status: string }>();
    expect(row?.plan).toBe("free");
    expect(row?.subscription_status).toBe("expired");
  });

  it("REFUND reverts to free/revoked", async () => {
    const userId = await seedSubscriber("pro");
    await post(makeSignedNotification({ notificationType: "REFUND", originalTransactionId: ORIG_TXN }));
    const row = await env.DB.prepare("SELECT plan, subscription_status FROM users WHERE id = ?")
      .bind(userId).first<{ plan: string; subscription_status: string }>();
    expect(row?.plan).toBe("free");
    expect(row?.subscription_status).toBe("revoked");
  });

  it("acks (200) when no user matches the originalTransactionId (idempotent)", async () => {
    const res = await post(makeSignedNotification({
      notificationType: "SUBSCRIBED",
      originalTransactionId: "9999999999",
    }));
    expect(res.status).toBe(200);
  });

  it("rejects a body without signedPayload (400 VALIDATION_FAILED)", async () => {
    const res = await SELF.fetch("https://api.test/appstore/notifications", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({}),
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe("VALIDATION_FAILED");
  });
});
