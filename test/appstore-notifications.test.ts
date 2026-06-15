import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { makeSignedNotification } from "./helpers/appstore";
import { makeTestChain } from "./helpers/appleChain";

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
    const res = await post(await makeSignedNotification({
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
    const res = await post(await makeSignedNotification({
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
    await post(await makeSignedNotification({ notificationType: "REFUND", originalTransactionId: ORIG_TXN }));
    const row = await env.DB.prepare("SELECT plan, subscription_status FROM users WHERE id = ?")
      .bind(userId).first<{ plan: string; subscription_status: string }>();
    expect(row?.plan).toBe("free");
    expect(row?.subscription_status).toBe("revoked");
  });

  it("acks (200) when no user matches the originalTransactionId (idempotent)", async () => {
    const res = await post(await makeSignedNotification({
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

  // Fix 1: NOOP types — webhook acks but does NOT update the row.
  it("CONSUMPTION_REQUEST is acked (200) but does not change user plan", async () => {
    const userId = await seedSubscriber("pro");
    const res = await post(await makeSignedNotification({
      notificationType: "CONSUMPTION_REQUEST",
      originalTransactionId: ORIG_TXN,
    }));
    expect(res.status).toBe(200);
    const body = (await res.json()) as { ok: boolean; ignored?: string };
    expect(body.ignored).toBe("noop");
    // Row should be unchanged.
    const row = await env.DB.prepare("SELECT plan FROM users WHERE id = ?")
      .bind(userId).first<{ plan: string }>();
    expect(row?.plan).toBe("pro");
  });

  // Fix 2: replay / ordering guard.
  it("stale EXPIRED cannot revert a newer DID_RENEW (monotonic replay guard)", async () => {
    const userId = await seedSubscriber("free");
    const newerTs = Date.now();
    const olderTs = newerTs - 60_000; // 1 minute earlier

    // 1. Apply a fresh DID_RENEW (newer).
    const renewRes = await post(await makeSignedNotification({
      notificationType: "DID_RENEW",
      originalTransactionId: ORIG_TXN,
      expiresDateMs: 9_999_999_999_000,
      signedDateMs: newerTs,
    }));
    expect(renewRes.status).toBe(200);

    // Confirm user is now pro.
    const afterRenew = await env.DB.prepare("SELECT plan FROM users WHERE id = ?")
      .bind(userId).first<{ plan: string }>();
    expect(afterRenew?.plan).toBe("pro");

    // 2. Replay an older EXPIRED (stale) — must be ignored by the monotonic guard.
    const expiredRes = await post(await makeSignedNotification({
      notificationType: "EXPIRED",
      originalTransactionId: ORIG_TXN,
      signedDateMs: olderTs,
    }));
    expect(expiredRes.status).toBe(200);

    // User must still be pro — the stale revoke was ignored.
    const afterStaleExpiry = await env.DB.prepare("SELECT plan, subscription_status FROM users WHERE id = ?")
      .bind(userId).first<{ plan: string; subscription_status: string }>();
    expect(afterStaleExpiry?.plan).toBe("pro");
    expect(afterStaleExpiry?.subscription_status).toBe("active");
  });

  // Fix 2: equal signedDate (same timestamp) should be applied (>= guard).
  it("event with same signedDate as last applied IS applied (>= not >)", async () => {
    const userId = await seedSubscriber("pro");
    const ts = Date.now();

    // Apply EXPIRED at ts.
    await post(await makeSignedNotification({
      notificationType: "EXPIRED",
      originalTransactionId: ORIG_TXN,
      signedDateMs: ts,
    }));
    const afterExpiry = await env.DB.prepare("SELECT plan FROM users WHERE id = ?")
      .bind(userId).first<{ plan: string }>();
    expect(afterExpiry?.plan).toBe("free");

    // Replay SUBSCRIBED at same ts — should apply (>= guard).
    await post(await makeSignedNotification({
      notificationType: "SUBSCRIBED",
      originalTransactionId: ORIG_TXN,
      signedDateMs: ts,
    }));
    const afterResub = await env.DB.prepare("SELECT plan FROM users WHERE id = ?")
      .bind(userId).first<{ plan: string }>();
    expect(afterResub?.plan).toBe("pro");
  });

  // Fix 3: body-size cap (signedPayload > 32 KiB → 400 VALIDATION_FAILED).
  it("rejects an oversized signedPayload (> 32768 chars) with 400 VALIDATION_FAILED", async () => {
    const oversize = "x".repeat(32_769);
    const res = await SELF.fetch("https://api.test/appstore/notifications", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ signedPayload: oversize }),
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe("VALIDATION_FAILED");
  });

  // Fix 4: missing/empty originalTransactionId → 400 (after the payload VERIFIES).
  it("rejects a (verified) notification with an empty originalTransactionId (400)", async () => {
    // Signed by the TRUSTED test chain so it passes JWS verification, but carries
    // an empty originalTransactionId → hits the empty-otid guard, not signature.
    const res = await post(await makeSignedNotification({
      notificationType: "SUBSCRIBED",
      originalTransactionId: "",
    }));
    expect(res.status).toBe(400);
  });

  // SECURITY: a notification signed by an UNTRUSTED chain (root != pinned anchor)
  // is rejected (401) and the DB is NEVER touched — no plan flip.
  it("rejects an UNTRUSTED-chain notification (401) and does not write the DB", async () => {
    const userId = await seedSubscriber("free");
    const untrusted = await makeTestChain(); // fresh root, not the pinned anchor
    const res = await post(await makeSignedNotification({
      notificationType: "SUBSCRIBED",
      originalTransactionId: ORIG_TXN,
      expiresDateMs: 9_999_999_999_000,
      chain: untrusted,
    }));
    expect(res.status).toBe(401);
    const body = (await res.json()) as { ok: boolean; error: string };
    expect(body.error).toBe("SIGNATURE_INVALID");

    // The seeded user must still be free — the forged REVOKE/SUBSCRIBED was ignored.
    const row = await env.DB.prepare("SELECT plan, subscription_status FROM users WHERE id = ?")
      .bind(userId).first<{ plan: string; subscription_status: string | null }>();
    expect(row?.plan).toBe("free");
  });

  // SECURITY: a TAMPERED payload (body mutated after signing) fails verification → 401, no write.
  it("rejects a TAMPERED notification (401) and does not write the DB", async () => {
    const userId = await seedSubscriber("free");
    const good = await makeSignedNotification({
      notificationType: "SUBSCRIBED",
      originalTransactionId: ORIG_TXN,
    });
    // Mutate the outer payload segment, keep header + signature.
    const [h, , s] = good.split(".");
    const evilPayload = btoa(JSON.stringify({ notificationType: "SUBSCRIBED", signedDate: Date.now(), data: {} }))
      .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
    const tampered = `${h}.${evilPayload}.${s}`;

    const res = await post(tampered);
    expect(res.status).toBe(401);
    const row = await env.DB.prepare("SELECT plan FROM users WHERE id = ?")
      .bind(userId).first<{ plan: string }>();
    expect(row?.plan).toBe("free");
  });
});
