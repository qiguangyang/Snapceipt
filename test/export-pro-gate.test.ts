import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { issueSession } from "../src/lib/sessions";

/** Seed a user (given plan) + a GST-registered business profile owned by them. */
async function seedUserWithBasProfile(plan: string): Promise<{ bearer: string; profileId: string }> {
  const userId = uuidv7();
  const deviceId = uuidv7();
  const profileId = uuidv7();
  const t = nowMs();
  await env.DB.prepare(
    "INSERT INTO users (id, email, email_verified, plan, created_at, updated_at) VALUES (?, ?, 1, ?, ?, ?)",
  ).bind(userId, `${userId}@example.com`, plan, t, t).run();
  await env.DB.prepare(
    `INSERT INTO profiles (id,user_id,name,type,gst_registered,abn,accent_1,accent_2,accent_3,created_at,updated_at)
     VALUES (?,?,'Acme Pty Ltd','business',1,'12 345 678 901','#0E7C72','#DCF0ED','#0A5950',?,?)`,
  ).bind(profileId, userId, t, t).run();
  const { accessToken } = await issueSession(env.DB, { userId, deviceId, signingKey: env.JWT_SIGNING_KEY });
  return { bearer: `Bearer ${accessToken}`, profileId };
}

beforeEach(async () => {
  await env.DB.exec("DELETE FROM transactions");
  await env.DB.exec("DELETE FROM profiles");
  await env.DB.exec("DELETE FROM sessions");
  await env.DB.exec("DELETE FROM users");
});

describe("POST /export {format:'bas'} is Pro-gated", () => {
  it("free user (owning a valid BAS profile) is 403 FORBIDDEN", async () => {
    const { bearer, profileId } = await seedUserWithBasProfile("free");
    const res = await SELF.fetch("https://x/export", {
      method: "POST",
      headers: { "content-type": "application/json", authorization: bearer },
      body: JSON.stringify({ profileId, format: "bas", from: "2026-04-01", to: "2026-06-30", bas: { paygInstalmentCents: 0 } }),
    });
    expect(res.status).toBe(403);
    const body = (await res.json()) as { error: { code: string; message: string } };
    expect(body.error.code).toBe("FORBIDDEN");
    // Distinguish the Pro gate from the ownership/eligibility gates (same code, different message).
    expect(body.error.message).toContain("Snapceipt Pro");
  });

  it("pro user (same profile) is NOT blocked by the Pro gate (200)", async () => {
    const { bearer, profileId } = await seedUserWithBasProfile("pro");
    const res = await SELF.fetch("https://x/export", {
      method: "POST",
      headers: { "content-type": "application/json", authorization: bearer },
      body: JSON.stringify({ profileId, format: "bas", from: "2026-04-01", to: "2026-06-30", bas: { paygInstalmentCents: 0 } }),
    });
    expect(res.status).toBe(200);
  });
});
