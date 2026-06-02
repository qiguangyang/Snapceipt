import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import {
  addressForToken,
  generateInboxToken,
  mintInboxToken,
  resolveInboxToken,
  rotateInboxToken,
  tokenFromRecipient,
} from "../src/lib/inboxToken";

async function seedProfile(): Promise<{ userId: string; profileId: string }> {
  const userId = uuidv7();
  const profileId = uuidv7();
  const t = nowMs();
  await env.DB.prepare(
    `INSERT INTO users (id, email, email_verified, plan, created_at, updated_at) VALUES (?, ?, 1, 'free', ?, ?)`,
  ).bind(userId, `${userId}@e.com`, t, t).run();
  await env.DB.prepare(
    `INSERT INTO profiles (id, user_id, name, type, accent_1, accent_2, accent_3, created_at, updated_at)
     VALUES (?, ?, 'Biz', 'business', '#0', '#1', '#2', ?, ?)`,
  ).bind(profileId, userId, t, t).run();
  return { userId, profileId };
}

beforeEach(async () => {
  await env.DB.exec("DELETE FROM profile_inbox_tokens");
  await env.DB.exec("DELETE FROM profiles");
  await env.DB.exec("DELETE FROM users");
});

describe("inboxToken — pure helpers", () => {
  it("generateInboxToken returns 32 lowercase hex chars and is unique", () => {
    const a = generateInboxToken();
    const b = generateInboxToken();
    expect(a).toMatch(/^[0-9a-f]{32}$/);
    expect(a).not.toBe(b);
  });

  it("addressForToken formats r.<token>@in.snapceipt.cc", () => {
    expect(addressForToken("abc")).toBe("r.abc@in.snapceipt.cc");
  });

  it("tokenFromRecipient extracts the token and rejects non-r. localparts", () => {
    expect(tokenFromRecipient("r.deadbeef@in.snapceipt.cc")).toBe("deadbeef");
    expect(tokenFromRecipient("R.DEADBEEF@IN.SNAPCEIPT.CC")).toBe("deadbeef");
    expect(tokenFromRecipient("noreply@snapceipt.cc")).toBeNull();
    expect(tokenFromRecipient("r.@in.snapceipt.cc")).toBeNull();
  });
});

describe("inboxToken — D1 helpers", () => {
  it("mint creates one token, is idempotent per profile, and resolves back to the owner", async () => {
    const { userId, profileId } = await seedProfile();
    const t1 = await mintInboxToken(env.DB, userId, profileId, nowMs());
    const t2 = await mintInboxToken(env.DB, userId, profileId, nowMs());
    expect(t1).toBe(t2); // idempotent — does not rotate
    const owner = await resolveInboxToken(env.DB, t1);
    expect(owner).toEqual({ userId, profileId });
  });

  it("rotate invalidates the old token and resolves the new one", async () => {
    const { userId, profileId } = await seedProfile();
    const old = await mintInboxToken(env.DB, userId, profileId, nowMs());
    const fresh = await rotateInboxToken(env.DB, userId, profileId, nowMs());
    expect(fresh).not.toBe(old);
    expect(await resolveInboxToken(env.DB, old)).toBeNull();
    expect(await resolveInboxToken(env.DB, fresh)).toEqual({ userId, profileId });
  });

  it("resolve returns null for an unknown token", async () => {
    expect(await resolveInboxToken(env.DB, "nope")).toBeNull();
  });
});
