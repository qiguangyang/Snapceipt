import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { issueSession } from "../src/lib/sessions";

async function seedUser(plan = "free"): Promise<{ bearer: string; userId: string }> {
  const userId = uuidv7();
  const deviceId = uuidv7();
  const t = nowMs();
  await env.DB.prepare(
    "INSERT INTO users (id, email, email_verified, plan, created_at, updated_at) VALUES (?, ?, 1, ?, ?, ?)",
  ).bind(userId, `${userId}@example.com`, plan, t, t).run();
  const { accessToken } = await issueSession(env.DB, { userId, deviceId, signingKey: env.JWT_SIGNING_KEY });
  return { bearer: `Bearer ${accessToken}`, userId };
}

beforeEach(async () => {
  await env.DB.exec("DELETE FROM sessions");
  await env.DB.exec("DELETE FROM users");
});

describe("POST /me/subscription (purchase link)", () => {
  it("stores the originalTransactionId and optimistically sets plan=pro", async () => {
    const { bearer, userId } = await seedUser("free");
    const res = await SELF.fetch("https://api.test/me/subscription", {
      method: "POST",
      headers: { "content-type": "application/json", authorization: bearer },
      body: JSON.stringify({
        originalTransactionId: "1000000999",
        expiresAtMs: 9_999_999_999_000,
        productId: "app.snapceipt.pro.monthly",
      }),
    });
    expect(res.status).toBe(200);
    const row = await env.DB.prepare(
      "SELECT plan, original_transaction_id, subscription_status FROM users WHERE id = ?",
    ).bind(userId).first<{ plan: string; original_transaction_id: string; subscription_status: string }>();
    expect(row?.plan).toBe("pro");
    expect(row?.original_transaction_id).toBe("1000000999");
    expect(row?.subscription_status).toBe("active");
  });

  it("requires authentication (401 without bearer)", async () => {
    const res = await SELF.fetch("https://api.test/me/subscription", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ originalTransactionId: "x", productId: "y" }),
    });
    expect(res.status).toBe(401);
  });
});
