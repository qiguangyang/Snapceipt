// test/images.test.ts
import { env } from "cloudflare:test";
import { Hono } from "hono";
import { beforeEach, describe, expect, it } from "vitest";
import type { AppEnv } from "../src/env";
import { requestId, registerErrorHandler } from "../src/middleware/error";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { imageRoutes } from "../src/routes/images";

/** A tiny valid-enough JPEG byte sequence (SOI ... EOI). Content is opaque to the worker. */
const JPEG_BYTES = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0xff, 0xd9]);

/**
 * Build a standalone app that mounts /images with a fixed authed identity and
 * the REAL D1 + R2 bindings injected onto c.env. No global auth/rate-limit —
 * those are exercised in Task 8's app-mount test (test/extract-app.test.ts).
 */
function appAs(userId: string, deviceId: string) {
  const app = new Hono<AppEnv>();
  app.use("*", requestId());
  registerErrorHandler(app);
  app.use("*", async (c, next) => {
    c.set("userId", userId);
    c.set("deviceId", deviceId);
    await next();
  });
  app.route("/images", imageRoutes);
  // Dispatch with the REAL Miniflare D1 + R2 bindings as c.env (Hono's third
  // request arg) — mirrors test/extract-route.test.ts. We thread a PLAIN object
  // holding the individual bindings (NOT the live `env` RPC proxy, which breaks
  // the vitest-pool-workers isolated-storage stacking on teardown). With bare
  // app.request() there is no Worker fetch handler supplying env, so c.env would
  // otherwise be undefined (the plan's middleware-mutation snippet — reconciled).
  const bindings = { DB: env.DB, RECEIPTS: env.RECEIPTS } as unknown as AppEnv["Bindings"];
  return {
    request: (input: string, init?: RequestInit) => app.request(input, init, bindings),
  };
}

/**
 * Insert a users row so the receipt_images.user_id / profiles.user_id FKs (the
 * real schema enforces them) are satisfied. The plan's bare seedTxn/appAs left
 * this out; reconciled to the real foreign-key constraints.
 */
async function seedUser(userId: string): Promise<void> {
  const now = nowMs();
  await env.DB.prepare(
    `INSERT INTO users (id, email, email_verified, display_name, plan, created_at, updated_at)
     VALUES (?, ?, 1, 'Dev', 'free', ?, ?)`,
  ).bind(userId, `${userId}@example.com`, now, now).run();
}

/** Insert a profile + transaction owned by userId; returns the txn id. */
async function seedTxn(userId: string): Promise<string> {
  const profileId = uuidv7();
  const txnId = uuidv7();
  const now = nowMs();
  await seedUser(userId);
  await env.DB.prepare(
    `INSERT INTO profiles (id,user_id,name,type,accent_1,accent_2,accent_3,created_at,updated_at)
     VALUES (?,?,'P','personal','#0E7C72','#DCF0ED','#0A5950',?,?)`,
  ).bind(profileId, userId, now, now).run();
  await env.DB.prepare(
    `INSERT INTO transactions (id,user_id,profile_id,cat_key,amount_cents,txn_date,created_at,updated_at)
     VALUES (?,?,?,'meals',-1250,'2026-05-30',?,?)`,
  ).bind(txnId, userId, profileId, now, now).run();
  return txnId;
}

beforeEach(async () => {
  await env.DB.exec("DELETE FROM receipt_images");
  await env.DB.exec("DELETE FROM line_items");
  await env.DB.exec("DELETE FROM transactions");
  await env.DB.exec("DELETE FROM profiles");
  await env.DB.exec("DELETE FROM sessions");
  await env.DB.exec("DELETE FROM devices");
  await env.DB.exec("DELETE FROM users");
});

describe("POST /images", () => {
  it("stores the JPEG in R2, inserts a receipt_images row, returns {imageKey,getUrl,byteSize}", async () => {
    const userId = uuidv7();
    const deviceId = uuidv7();
    const app = appAs(userId, deviceId);
    const txnId = await seedTxn(userId);

    const res = await app.request(
      `/images?transactionId=${txnId}&width=1200&height=1600`,
      { method: "POST", headers: { "content-type": "image/jpeg" }, body: JPEG_BYTES },
    );
    expect(res.status).toBe(200);
    const body = (await res.json()) as { imageKey: string; getUrl: string; byteSize: number };
    expect(body.imageKey).toMatch(new RegExp(`^u/${userId}/[0-9a-f-]+\\.jpg$`));
    expect(body.getUrl).toBe(`/images/${body.imageKey}`);
    expect(body.byteSize).toBe(JPEG_BYTES.byteLength);

    // R2 object exists (verified via the handler's own GET round-trip rather
    // than a direct env.RECEIPTS.get in the test runner context — mixing R2
    // access across the runner + worker contexts trips the vitest-pool-workers
    // isolated-storage teardown).
    const obj = await app.request(`/images/${body.imageKey}`);
    expect(obj.status).toBe(200);

    // receipt_images row exists with the FK link + metadata.
    const row = await env.DB.prepare(
      `SELECT user_id, transaction_id, r2_key, content_type, byte_size, width, height, page_index, source, ocr_source, last_edited_device_id
         FROM receipt_images WHERE r2_key = ?`,
    ).bind(body.imageKey).first<any>();
    expect(row.user_id).toBe(userId);
    expect(row.transaction_id).toBe(txnId);
    expect(row.content_type).toBe("image/jpeg");
    expect(row.byte_size).toBe(JPEG_BYTES.byteLength);
    expect(row.width).toBe(1200);
    expect(row.height).toBe(1600);
    expect(row.page_index).toBe(0);
    expect(row.source).toBe("scan");
    expect(row.ocr_source).toBe("vision_on_device");
    expect(row.last_edited_device_id).toBe(deviceId);
  });

  it("stores transaction_id = NULL when the txn does not exist for this user (FK-safe, still 200)", async () => {
    const userId = uuidv7();
    await seedUser(userId);
    const app = appAs(userId, uuidv7());
    const res = await app.request(`/images?transactionId=${uuidv7()}`, {
      method: "POST",
      headers: { "content-type": "image/jpeg" },
      body: JPEG_BYTES,
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { imageKey: string };
    const row = await env.DB.prepare(`SELECT transaction_id FROM receipt_images WHERE r2_key = ?`)
      .bind(body.imageKey).first<{ transaction_id: string | null }>();
    expect(row?.transaction_id).toBeNull();
  });

  it("rejects a non-image/jpeg content-type with 400", async () => {
    const app = appAs(uuidv7(), uuidv7());
    const res = await app.request("/images", {
      method: "POST",
      headers: { "content-type": "image/png" },
      body: JPEG_BYTES,
    });
    expect(res.status).toBe(400);
    expect(((await res.json()) as any).error.code).toBe("VALIDATION_FAILED");
  });

  it("rejects a body over 6 MiB with 400", async () => {
    const app = appAs(uuidv7(), uuidv7());
    const big = new Uint8Array(6_291_457); // 6 MiB + 1
    big[0] = 0xff; big[1] = 0xd8;
    const res = await app.request("/images", {
      method: "POST",
      headers: { "content-type": "image/jpeg" },
      body: big,
    });
    expect(res.status).toBe(400);
  });
});

describe("GET /images/*", () => {
  it("streams the owner's object back with its content-type", async () => {
    const userId = uuidv7();
    await seedUser(userId);
    const app = appAs(userId, uuidv7());
    const post = await app.request("/images", {
      method: "POST",
      headers: { "content-type": "image/jpeg" },
      body: JPEG_BYTES,
    });
    const { imageKey } = (await post.json()) as { imageKey: string };

    const get = await app.request(`/images/${imageKey}`);
    expect(get.status).toBe(200);
    expect(get.headers.get("content-type")).toBe("image/jpeg");
    const bytes = new Uint8Array(await get.arrayBuffer());
    expect(bytes.byteLength).toBe(JPEG_BYTES.byteLength);
  });

  it("returns 404 for another user's key (ownership enforced by prefix)", async () => {
    const ownerA = uuidv7();
    await seedUser(ownerA);
    const appA = appAs(ownerA, uuidv7());
    const post = await appA.request("/images", {
      method: "POST",
      headers: { "content-type": "image/jpeg" },
      body: JPEG_BYTES,
    });
    const { imageKey } = (await post.json()) as { imageKey: string };

    // A different user's app (different injected userId) cannot read A's key.
    const appB = appAs(uuidv7(), uuidv7());
    const get = await appB.request(`/images/${imageKey}`);
    expect(get.status).toBe(404);
  });

  it("returns 404 for an own-prefix key with no object", async () => {
    const userId = uuidv7();
    const app = appAs(userId, uuidv7());
    const get = await app.request(`/images/u/${userId}/${uuidv7()}.jpg`);
    expect(get.status).toBe(404);
  });
});

describe("GET /images/by-transaction/:transactionId", () => {
  it("streams the image linked to the txn for this user", async () => {
    const userId = uuidv7();
    const app = appAs(userId, uuidv7());
    const txnId = await seedTxn(userId);
    await app.request(`/images?transactionId=${txnId}`, {
      method: "POST", headers: { "content-type": "image/jpeg" }, body: JPEG_BYTES,
    });
    const get = await app.request(`/images/by-transaction/${txnId}`);
    expect(get.status).toBe(200);
    expect(get.headers.get("content-type")).toBe("image/jpeg");
    expect(new Uint8Array(await get.arrayBuffer()).byteLength).toBe(JPEG_BYTES.byteLength);
  });

  it("returns 404 when the txn has no image", async () => {
    const userId = uuidv7();
    const app = appAs(userId, uuidv7());
    const txnId = await seedTxn(userId);
    const get = await app.request(`/images/by-transaction/${txnId}`);
    expect(get.status).toBe(404);
  });

  it("does not return another user's image for the same txn id", async () => {
    const ownerA = uuidv7();
    const appA = appAs(ownerA, uuidv7());
    const txnId = await seedTxn(ownerA);
    await appA.request(`/images?transactionId=${txnId}`, {
      method: "POST", headers: { "content-type": "image/jpeg" }, body: JPEG_BYTES,
    });
    const appB = appAs(uuidv7(), uuidv7());
    const get = await appB.request(`/images/by-transaction/${txnId}`);
    expect(get.status).toBe(404);
  });
});
