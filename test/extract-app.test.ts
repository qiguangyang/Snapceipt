// test/extract-app.test.ts
import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { issueSession } from "../src/lib/sessions";

async function seedSession() {
  const userId = uuidv7();
  const deviceId = uuidv7();
  const now = nowMs();
  await env.DB.prepare(
    `INSERT INTO users (id, email, email_verified, display_name, plan, created_at, updated_at)
     VALUES (?, ?, 1, 'Dev', ?, ?, ?)`,
  ).bind(userId, `${userId}@example.com`, "free", now, now).run();
  await env.DB.prepare(
    `INSERT INTO devices (id, user_id, platform, push_enabled, created_at, updated_at)
     VALUES (?, ?, 'ios', 1, ?, ?)`,
  ).bind(deviceId, userId, now, now).run();
  const { accessToken } = await issueSession(env.DB, { userId, deviceId, signingKey: env.JWT_SIGNING_KEY });
  return { userId, deviceId, accessToken };
}

beforeEach(async () => {
  await env.DB.exec("DELETE FROM receipt_images");
  await env.DB.exec("DELETE FROM sessions");
  await env.DB.exec("DELETE FROM devices");
  await env.DB.exec("DELETE FROM users");
});

const OCR = "THE GROUNDS\n28/05/2026\nTOTAL 33.00";
const JPEG_BYTES = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0xff, 0xd9]);

describe("POST /extract (through the real app)", () => {
  it("requires auth (401 without a bearer token)", async () => {
    const res = await SELF.fetch("https://x/extract", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ ocrText: OCR, source: "scan" }),
    });
    expect(res.status).toBe(401);
  });

  it("returns the stub §9 shape for an authed request (no DeepSeek key in tests)", async () => {
    const { accessToken } = await seedSession();
    const res = await SELF.fetch("https://x/extract", {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
      body: JSON.stringify({ ocrText: OCR, source: "scan" }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;
    expect(body.receipt.currencyCode).toBe("AUD");
    expect(body.meta.stub).toBe(true);
    expect(body.meta.source).toBe("scan");
    expect(body.meta.attempts).toBe(0); // stub path
  });

  it("rate-limits the extract tier at 30/user/hr (the 31st request is 429)", async () => {
    const { accessToken } = await seedSession();
    const headers = { authorization: `Bearer ${accessToken}`, "content-type": "application/json" };
    const body = JSON.stringify({ ocrText: OCR, source: "scan" });
    let last = 200;
    for (let i = 0; i < 31; i++) {
      const res = await SELF.fetch("https://x/extract", { method: "POST", headers, body });
      last = res.status;
    }
    expect(last).toBe(429); // exact-path limiter engaged for POST /extract
  });
});

describe("/images (through the real app)", () => {
  it("requires auth (401 without a bearer token)", async () => {
    const res = await SELF.fetch("https://x/images", {
      method: "POST",
      headers: { "content-type": "image/jpeg" },
      body: JPEG_BYTES,
    });
    expect(res.status).toBe(401);
  });

  it("POST /images then GET /images/* round-trips for the owner (exact-path mount works)", async () => {
    const { accessToken, deviceId } = await seedSession();
    const post = await SELF.fetch("https://x/images", {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "image/jpeg", "x-device-id": deviceId },
      body: JPEG_BYTES,
    });
    expect(post.status).toBe(200);
    const { imageKey, getUrl } = (await post.json()) as { imageKey: string; getUrl: string };
    const get = await SELF.fetch(`https://x${getUrl}`, { headers: { authorization: `Bearer ${accessToken}` } });
    expect(get.status).toBe(200);
    expect(get.headers.get("content-type")).toBe("image/jpeg");
    expect(getUrl).toBe(`/images/${imageKey}`);
  });
});
