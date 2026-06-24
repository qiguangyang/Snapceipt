import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { issueSession } from "../src/lib/sessions";

// End-to-end coverage for the dev simulator POST /devices/simulate-inbound: it must run the
// REAL email-in ingestion (extract → create txn → push) for the authed Pro user, attach the
// receipt to the ALIAS profile (what the Email-in screen shows), and the txn must be pullable
// via /sync/pull so the app actually receives it. Extraction uses the deterministic stub here
// (no GEMINI_API_KEY in tests), so `extraction` is "done" with the ACME stub receipt.

const IMG = new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8]);

async function seedProUserWithDevice() {
  const userId = uuidv7();
  const deviceId = uuidv7();
  const t = nowMs();
  await env.DB.prepare(
    `INSERT INTO users (id, email, email_verified, plan, subscription_status, created_at, updated_at)
     VALUES (?, ?, 1, 'pro', 'active', ?, ?)`,
  ).bind(userId, `${userId}@e.com`, t, t).run();
  await env.DB.prepare(
    `INSERT INTO devices (id, user_id, platform, push_enabled, apns_token, apns_environment, created_at, updated_at)
     VALUES (?, ?, 'ios', 1, ?, 'development', ?, ?)`,
  ).bind(deviceId, userId, `tok-${deviceId}`, t, t).run();
  const { accessToken } = await issueSession(env.DB, { userId, deviceId, signingKey: env.JWT_SIGNING_KEY });
  return { userId, deviceId, bearer: `Bearer ${accessToken}`, t };
}

async function addProfile(userId: string, name: string, createdAt: number): Promise<string> {
  const id = uuidv7();
  await env.DB.prepare(
    `INSERT INTO profiles (id, user_id, name, type, accent_1, accent_2, accent_3, created_at, updated_at)
     VALUES (?, ?, ?, 'personal', '#0', '#1', '#2', ?, ?)`,
  ).bind(id, userId, name, createdAt, createdAt).run();
  return id;
}

async function addAlias(userId: string, profileId: string, createdAt: number) {
  await env.DB.prepare(
    `INSERT INTO profile_inbox_tokens (token, user_id, profile_id, created_at) VALUES (?, ?, ?, ?)`,
  ).bind(uuidv7(), userId, profileId, createdAt).run();
}

beforeEach(async () => {
  for (const tbl of [
    "receipt_images", "line_items", "transactions", "profile_inbox_tokens",
    "sessions", "devices", "profiles", "users",
  ]) {
    await env.DB.exec(`DELETE FROM ${tbl}`);
  }
});

describe("POST /devices/simulate-inbound (full email-in simulation)", () => {
  it("creates an email_in txn on the ALIAS profile (not the oldest) and counts the push device", async () => {
    const { userId, bearer, t } = await seedProUserWithDevice();
    await addProfile(userId, "Old", t);                                 // oldest, NO alias
    const aliasProfile = await addProfile(userId, "Alias", t + 1000);   // newer, HAS alias
    await addAlias(userId, aliasProfile, t + 1000);

    const res = await SELF.fetch("https://x/devices/simulate-inbound", {
      method: "POST",
      headers: { authorization: bearer, "content-type": "image/jpeg" },
      body: IMG,
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { transactionId: string; extraction: string; deviceCount: number };
    expect(body.transactionId).toBeTruthy();
    expect(body.extraction).toBe("done"); // deterministic stub (no GEMINI_API_KEY in tests)
    expect(body.deviceCount).toBe(1);

    const txn = await env.DB.prepare(`SELECT profile_id, source FROM transactions WHERE id = ?`)
      .bind(body.transactionId).first<{ profile_id: string; source: string }>();
    expect(txn?.profile_id).toBe(aliasProfile); // the alias profile, NOT the oldest
    expect(txn?.source).toBe("email_in");
  });

  it("?profileId attaches the receipt to the requested (active) profile, not the alias one", async () => {
    const { userId, bearer, t } = await seedProUserWithDevice();
    const active = await addProfile(userId, "Active", t);          // the profile the user is viewing
    const aliasProfile = await addProfile(userId, "Aliased", t + 1000); // newer alias → the fallback pick
    await addAlias(userId, aliasProfile, t + 1000);

    const res = await SELF.fetch(`https://x/devices/simulate-inbound?profileId=${active}`, {
      method: "POST", headers: { authorization: bearer, "content-type": "image/jpeg" }, body: IMG,
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { transactionId: string };
    const txn = await env.DB.prepare(`SELECT profile_id FROM transactions WHERE id = ?`)
      .bind(body.transactionId).first<{ profile_id: string }>();
    expect(txn?.profile_id).toBe(active); // honoured the requested profile over the newer alias
  });

  it("a ?profileId not owned by the user is ignored (falls back), never cross-user", async () => {
    const a = await seedProUserWithDevice();
    const ap = await addProfile(a.userId, "A", a.t); await addAlias(a.userId, ap, a.t);
    const b = await seedProUserWithDevice();
    const bp = await addProfile(b.userId, "B", b.t); await addAlias(b.userId, bp, b.t);
    // User A requests user B's profile id → must NOT attach to B's profile.
    const res = await SELF.fetch(`https://x/devices/simulate-inbound?profileId=${bp}`, {
      method: "POST", headers: { authorization: a.bearer, "content-type": "image/jpeg" }, body: IMG,
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { transactionId: string };
    const txn = await env.DB.prepare(`SELECT profile_id FROM transactions WHERE id = ?`)
      .bind(body.transactionId).first<{ profile_id: string }>();
    expect(txn?.profile_id).toBe(ap); // fell back to A's own profile, not B's
  });

  it("the created transaction is returned by /sync/pull (so the app receives it)", async () => {
    const { userId, bearer, t } = await seedProUserWithDevice();
    const p = await addProfile(userId, "P", t);
    await addAlias(userId, p, t);

    const sim = (await (await SELF.fetch("https://x/devices/simulate-inbound", {
      method: "POST", headers: { authorization: bearer, "content-type": "image/jpeg" }, body: IMG,
    })).json()) as { transactionId: string };

    const pull = await SELF.fetch("https://x/sync/pull?limit=500", { headers: { authorization: bearer } });
    expect(pull.status).toBe(200);
    const pulled = JSON.stringify(await pull.json());
    expect(pulled).toContain(sim.transactionId); // the new receipt is in the sync payload
  });
});
