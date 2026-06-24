import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { issueSession } from "../src/lib/sessions";

async function seedAuthedProfile(plan: "free" | "pro" = "free"): Promise<{ profileId: string; bearer: string; userId: string }> {
  const userId = uuidv7();
  const deviceId = uuidv7();
  const profileId = uuidv7();
  const t = nowMs();
  // A Pro user is plan=pro with no recorded expiry (isProUser treats expires_at == null as entitled).
  await env.DB.prepare(
    `INSERT INTO users (id, email, email_verified, plan, subscription_status, created_at, updated_at) VALUES (?, ?, 1, ?, ?, ?, ?)`,
  ).bind(userId, `${userId}@e.com`, plan, plan === "pro" ? "active" : null, t, t).run();
  await env.DB.prepare(
    `INSERT INTO devices (id, user_id, platform, push_enabled, created_at, updated_at) VALUES (?, ?, 'ios', 1, ?, ?)`,
  ).bind(deviceId, userId, t, t).run();
  await env.DB.prepare(
    `INSERT INTO profiles (id, user_id, name, type, accent_1, accent_2, accent_3, created_at, updated_at)
     VALUES (?, ?, 'Biz', 'business', '#0', '#1', '#2', ?, ?)`,
  ).bind(profileId, userId, t, t).run();
  const { accessToken } = await issueSession(env.DB, { userId, deviceId, signingKey: env.JWT_SIGNING_KEY });
  return { profileId, bearer: `Bearer ${accessToken}`, userId };
}

beforeEach(async () => {
  await env.DB.exec("DELETE FROM profile_inbox_tokens");
  await env.DB.exec("DELETE FROM sessions");
  await env.DB.exec("DELETE FROM devices");
  await env.DB.exec("DELETE FROM profiles");
  await env.DB.exec("DELETE FROM users");
});

describe("GET /profiles/:id/inbox", () => {
  it("mints + returns a well-formed inbox address scoped to the profile", async () => {
    const { profileId, bearer } = await seedAuthedProfile("pro");
    const res = await SELF.fetch(`https://x/profiles/${profileId}/inbox`, { headers: { authorization: bearer } });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { profileId: string; token: string; address: string };
    expect(body.profileId).toBe(profileId);
    expect(body.token).toMatch(/^[0-9a-f]{32}$/);
    expect(body.address).toBe(`r.${body.token}@in.snapceipt.cc`);

    // Idempotent: a second GET returns the same token.
    const again = await SELF.fetch(`https://x/profiles/${profileId}/inbox`, { headers: { authorization: bearer } });
    expect(((await again.json()) as { token: string }).token).toBe(body.token);
  });

  it("404s for a profile the caller does not own", async () => {
    const { bearer } = await seedAuthedProfile();
    const res = await SELF.fetch(`https://x/profiles/${uuidv7()}/inbox`, { headers: { authorization: bearer } });
    expect(res.status).toBe(404);
  });

  it("401s without a bearer token", async () => {
    const { profileId } = await seedAuthedProfile();
    const res = await SELF.fetch(`https://x/profiles/${profileId}/inbox`);
    expect(res.status).toBe(401);
  });
});

describe("POST /profiles/:id/inbox/rotate", () => {
  it("returns a different token than the one GET minted", async () => {
    const { profileId, bearer } = await seedAuthedProfile("pro");
    const first = (await (await SELF.fetch(`https://x/profiles/${profileId}/inbox`, { headers: { authorization: bearer } })).json()) as { token: string };
    const rotated = (await (await SELF.fetch(`https://x/profiles/${profileId}/inbox/rotate`, { method: "POST", headers: { authorization: bearer } })).json()) as { token: string; address: string };
    expect(rotated.token).not.toBe(first.token);
    expect(rotated.address).toBe(`r.${rotated.token}@in.snapceipt.cc`);
  });
});

// Email-in is Pro-only: the alias mint/rotate routes are Pro-gated server-side
// (defence in depth alongside the inbound bounce + the iOS paywall). The Pro gate
// runs AFTER the ownership check, so a non-owner still gets 404 (above), while an
// owned-but-free user gets 403 FORBIDDEN.
describe("inbox alias routes are Pro-gated", () => {
  it("GET /profiles/:id/inbox is 403 FORBIDDEN for an owned, free user", async () => {
    const { profileId, bearer } = await seedAuthedProfile("free");
    const res = await SELF.fetch(`https://x/profiles/${profileId}/inbox`, { headers: { authorization: bearer } });
    expect(res.status).toBe(403);
    const body = (await res.json()) as { error: { code: string; message: string } };
    expect(body.error.code).toBe("FORBIDDEN");
    expect(body.error.message).toContain("Snapceipt Pro");
  });

  it("GET /profiles/:id/inbox returns the alias for a pro user", async () => {
    const { profileId, bearer } = await seedAuthedProfile("pro");
    const res = await SELF.fetch(`https://x/profiles/${profileId}/inbox`, { headers: { authorization: bearer } });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { address: string };
    expect(body.address).toMatch(/@in\.snapceipt\.cc$/);
  });

  it("POST /profiles/:id/inbox/rotate is 403 FORBIDDEN for an owned, free user", async () => {
    const { profileId, bearer } = await seedAuthedProfile("free");
    const res = await SELF.fetch(`https://x/profiles/${profileId}/inbox/rotate`, { method: "POST", headers: { authorization: bearer } });
    expect(res.status).toBe(403);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe("FORBIDDEN");
  });
});
