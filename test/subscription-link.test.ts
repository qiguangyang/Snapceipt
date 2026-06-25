import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { issueSession } from "../src/lib/sessions";
import { makeSignedTransaction } from "./helpers/appstore";
import { makeTestChain } from "./helpers/appleChain";

// The bundle id the verifier asserts against — pinned in vitest.config.ts.
const BUNDLE_ID = (env as { APPLE_BUNDLE_ID: string }).APPLE_BUNDLE_ID;

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

function post(bearer: string, body: unknown) {
  return SELF.fetch("https://api.test/me/subscription", {
    method: "POST",
    headers: { "content-type": "application/json", authorization: bearer },
    body: JSON.stringify(body),
  });
}

async function planOf(userId: string) {
  return env.DB.prepare(
    "SELECT plan, original_transaction_id, subscription_status, subscription_expires_at FROM users WHERE id = ?",
  ).bind(userId).first<{
    plan: string;
    original_transaction_id: string | null;
    subscription_status: string | null;
    subscription_expires_at: number | null;
  }>();
}

beforeEach(async () => {
  await env.DB.exec("DELETE FROM sessions");
  await env.DB.exec("DELETE FROM users");
});

describe("POST /me/subscription (verified purchase link)", () => {
  it("flips plan=pro from the VERIFIED transaction (not client-asserted fields)", async () => {
    const { bearer, userId } = await seedUser("free");
    const signedTransaction = await makeSignedTransaction({
      bundleId: BUNDLE_ID,
      productId: "app.snapceipt.pro.monthly",
      originalTransactionId: "1000000999",
      expiresDate: 9_999_999_999_000,
    });
    // The body carries ONLY the signed JWS — no client originalTransactionId/expiry.
    const res = await post(bearer, { signedTransaction });
    expect(res.status).toBe(200);

    const row = await planOf(userId);
    expect(row?.plan).toBe("pro");
    // Linkage fields came from the verified payload.
    expect(row?.original_transaction_id).toBe("1000000999");
    expect(row?.subscription_status).toBe("active");
    expect(row?.subscription_expires_at).toBe(9_999_999_999_000);
  });

  it("ACCEPTS a Sandbox-environment transaction (TestFlight/sandbox testers get Pro)", async () => {
    // There is deliberately no environment gate: a sandbox JWS is still Apple-signed (the verified
    // x5c chain proves authenticity), and testers must be able to unlock Pro.
    const { bearer, userId } = await seedUser("free");
    const signedTransaction = await makeSignedTransaction({
      bundleId: BUNDLE_ID,
      productId: "app.snapceipt.pro.monthly",
      originalTransactionId: "1000001234",
      environment: "Sandbox",
    });
    const res = await post(bearer, { signedTransaction });
    expect(res.status).toBe(200);
    expect((await planOf(userId))?.plan).toBe("pro");
  });

  it("rejects a TAMPERED transaction (401) and does NOT flip the plan", async () => {
    const { bearer, userId } = await seedUser("free");
    const good = await makeSignedTransaction({
      bundleId: BUNDLE_ID,
      productId: "app.snapceipt.pro.monthly",
      originalTransactionId: "1000000999",
    });
    const [h, , s] = good.split(".");
    const evil = btoa(JSON.stringify({
      bundleId: BUNDLE_ID, productId: "app.snapceipt.pro.yearly", originalTransactionId: "EVIL",
    })).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
    const tampered = `${h}.${evil}.${s}`;

    const res = await post(bearer, { signedTransaction: tampered });
    expect(res.status).toBe(401);
    const row = await planOf(userId);
    expect(row?.plan).toBe("free");
    expect(row?.original_transaction_id).toBeNull();
  });

  it("rejects an UNTRUSTED-chain transaction (401) and does NOT flip the plan", async () => {
    const { bearer, userId } = await seedUser("free");
    const untrusted = await makeTestChain();
    const signedTransaction = await makeSignedTransaction({
      bundleId: BUNDLE_ID,
      productId: "app.snapceipt.pro.monthly",
      originalTransactionId: "1000000999",
      chain: untrusted,
    });
    const res = await post(bearer, { signedTransaction });
    expect(res.status).toBe(401);
    expect((await planOf(userId))?.plan).toBe("free");
  });

  it("rejects a transaction for the WRONG bundle id (400) and does NOT flip", async () => {
    const { bearer, userId } = await seedUser("free");
    const signedTransaction = await makeSignedTransaction({
      bundleId: "com.evil.other",
      productId: "app.snapceipt.pro.monthly",
      originalTransactionId: "1000000999",
    });
    const res = await post(bearer, { signedTransaction });
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: string };
    expect(body.error).toBe("BUNDLE_MISMATCH");
    expect((await planOf(userId))?.plan).toBe("free");
  });

  it("rejects a transaction for a NON-Pro product (400) and does NOT flip", async () => {
    const { bearer, userId } = await seedUser("free");
    const signedTransaction = await makeSignedTransaction({
      bundleId: BUNDLE_ID,
      productId: "app.snapceipt.consumable.tip",
      originalTransactionId: "1000000999",
    });
    const res = await post(bearer, { signedTransaction });
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: string };
    expect(body.error).toBe("PRODUCT_NOT_PRO");
    expect((await planOf(userId))?.plan).toBe("free");
  });

  it("accepts the yearly Pro product too", async () => {
    const { bearer, userId } = await seedUser("free");
    const signedTransaction = await makeSignedTransaction({
      bundleId: BUNDLE_ID,
      productId: "app.snapceipt.pro.yearly",
      originalTransactionId: "1000001000",
    });
    const res = await post(bearer, { signedTransaction });
    expect(res.status).toBe(200);
    expect((await planOf(userId))?.plan).toBe("pro");
  });

  it("rejects a REVOKED (refunded) transaction (400) and does NOT flip the plan", async () => {
    const { bearer, userId } = await seedUser("free");
    const signedTransaction = await makeSignedTransaction({
      bundleId: BUNDLE_ID,
      productId: "app.snapceipt.pro.monthly",
      originalTransactionId: "1000002000",
      revocationDate: 1_700_000_000_000,
    });
    const res = await post(bearer, { signedTransaction });
    expect(res.status).toBe(400);
    expect((await res.json() as { error: string }).error).toBe("TRANSACTION_REVOKED");
    expect((await planOf(userId))?.plan).toBe("free");
  });

  it("rejects an EXPIRED transaction (400) and does NOT flip the plan", async () => {
    const { bearer, userId } = await seedUser("free");
    const signedTransaction = await makeSignedTransaction({
      bundleId: BUNDLE_ID,
      productId: "app.snapceipt.pro.monthly",
      originalTransactionId: "1000002001",
      expiresDate: 1_000_000_000_000, // 2001 — long past
    });
    const res = await post(bearer, { signedTransaction });
    expect(res.status).toBe(400);
    expect((await res.json() as { error: string }).error).toBe("TRANSACTION_EXPIRED");
    expect((await planOf(userId))?.plan).toBe("free");
  });

  it("rejects binding one Apple subscription to a SECOND account (409)", async () => {
    const a = await seedUser("free");
    const b = await seedUser("free");
    const otid = "1000002002";
    const txnA = await makeSignedTransaction({
      bundleId: BUNDLE_ID, productId: "app.snapceipt.pro.monthly", originalTransactionId: otid,
    });
    expect((await post(a.bearer, { signedTransaction: txnA })).status).toBe(200);
    expect((await planOf(a.userId))?.plan).toBe("pro");

    const txnB = await makeSignedTransaction({
      bundleId: BUNDLE_ID, productId: "app.snapceipt.pro.monthly", originalTransactionId: otid,
    });
    const res = await post(b.bearer, { signedTransaction: txnB });
    expect(res.status).toBe(409);
    expect((await res.json() as { error: string }).error).toBe("SUBSCRIPTION_ALREADY_LINKED");
    expect((await planOf(b.userId))?.plan).toBe("free");
  });

  it("requires authentication (401 without bearer)", async () => {
    const res = await SELF.fetch("https://api.test/me/subscription", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ signedTransaction: "x" }),
    });
    expect(res.status).toBe(401);
  });
});
