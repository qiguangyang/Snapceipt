import { env, SELF, applyD1Migrations } from "cloudflare:test";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import * as emailModule from "../src/lib/email";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { issueSession } from "../src/lib/sessions";
import { verifyDownloadToken } from "../src/lib/exportToken";

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});
afterEach(() => vi.restoreAllMocks());

beforeEach(async () => {
  await env.DB.exec("DELETE FROM email_outbox");
  await env.DB.exec("DELETE FROM receipt_images");
  await env.DB.exec("DELETE FROM transactions");
  await env.DB.exec("DELETE FROM tax_settings");
  await env.DB.exec("DELETE FROM profiles");
  await env.DB.exec("DELETE FROM sessions");
  await env.DB.exec("DELETE FROM devices");
  await env.DB.exec("DELETE FROM users");
});

const BASE = "https://api.test";

/** Seed a user + device + session, return the access token + ids. */
async function seedAuthed() {
  const userId = uuidv7();
  const deviceId = uuidv7();
  const now = nowMs();
  await env.DB.prepare(
    `INSERT INTO users (id, email, email_verified, display_name, plan, created_at, updated_at)
     VALUES (?, ?, 1, 'Dev', 'free', ?, ?)`,
  ).bind(userId, `${userId}@example.com`, now, now).run();
  await env.DB.prepare(
    `INSERT INTO devices (id, user_id, platform, push_enabled, created_at, updated_at)
     VALUES (?, ?, 'ios', 1, ?, ?)`,
  ).bind(deviceId, userId, now, now).run();
  const { accessToken } = await issueSession(env.DB, { userId, deviceId, signingKey: env.JWT_SIGNING_KEY });
  return { userId, deviceId, accessToken, email: `${userId}@example.com` };
}

/** Seed a business profile + 2 txns (one with a receipt image) for a user. */
async function seedProfileData(userId: string) {
  const profileId = uuidv7();
  const t1 = uuidv7();
  const t2 = uuidv7();
  const imgId = uuidv7();
  const now = nowMs();
  await env.DB.prepare(
    `INSERT INTO profiles (id,user_id,name,type,accent_1,accent_2,accent_3,created_at,updated_at)
     VALUES (?,?,'Acme Pty Ltd','business','#0E7C72','#DCF0ED','#0A5950',?,?)`,
  ).bind(profileId, userId, now, now).run();
  await env.DB.prepare(
    `INSERT INTO transactions (id,user_id,profile_id,merchant,cat_key,amount_cents,gst_cents,deductible_pct,payment_method,note,txn_date,created_at,updated_at)
     VALUES (?,?,?,'The Grounds','meals',-3300,300,50,'card','client lunch','2026-05-30',?,?)`,
  ).bind(t1, userId, profileId, now, now).run();
  await env.DB.prepare(
    `INSERT INTO transactions (id,user_id,profile_id,merchant,cat_key,amount_cents,gst_cents,deductible_pct,txn_date,created_at,updated_at)
     VALUES (?,?,?,'Officeworks','office',-8800,800,100,'2026-05-12',?,?)`,
  ).bind(t2, userId, profileId, now, now).run();
  await env.DB.prepare(
    `INSERT INTO receipt_images (id,user_id,profile_id,transaction_id,r2_key,created_at,updated_at)
     VALUES (?,?,?,?,?,?,?)`,
  ).bind(imgId, userId, profileId, t1, `u/${userId}/r/${imgId}.jpg`, now, now).run();
  return { profileId, t1, t2, imgKey: `u/${userId}/r/${imgId}.jpg` };
}

describe("POST /export", () => {
  it("csv -> 200 { url, expiresAt } and the url is a public /export/dl/:token", async () => {
    const { userId, accessToken } = await seedAuthed();
    const { profileId } = await seedProfileData(userId);
    const res = await SELF.fetch(`${BASE}/export`, {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
      body: JSON.stringify({ profileId, format: "csv", from: "2026-05-01", to: "2026-05-31" }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { url: string; expiresAt: number };
    expect(body.url).toContain("/export/dl/");
    expect(typeof body.expiresAt).toBe("number");
  });

  it("pdf -> 200 { url, expiresAt }; the downloaded object is a real %PDF", async () => {
    const { userId, accessToken } = await seedAuthed();
    const { profileId } = await seedProfileData(userId);
    const res = await SELF.fetch(`${BASE}/export`, {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
      body: JSON.stringify({ profileId, format: "pdf", from: "2026-05-01", to: "2026-05-31" }),
    });
    expect(res.status).toBe(200);
    const { url } = (await res.json()) as { url: string };
    const dl = await SELF.fetch(url);
    expect(dl.status).toBe(200);
    expect(dl.headers.get("content-type")).toContain("application/pdf");
    const bytes = new Uint8Array(await dl.arrayBuffer());
    expect(bytes[0]).toBe(0x25); // %
  });

  it("rejects a profile owned by another user with 403 FORBIDDEN", async () => {
    const { accessToken } = await seedAuthed();
    const other = await seedAuthed();
    const { profileId } = await seedProfileData(other.userId);
    const res = await SELF.fetch(`${BASE}/export`, {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
      body: JSON.stringify({ profileId, format: "csv", from: "2026-05-01", to: "2026-05-31" }),
    });
    expect(res.status).toBe(403);
    expect(((await res.json()) as any).error.code).toBe("FORBIDDEN");
  });

  it("rejects from > to with 400 VALIDATION_FAILED", async () => {
    const { userId, accessToken } = await seedAuthed();
    const { profileId } = await seedProfileData(userId);
    const res = await SELF.fetch(`${BASE}/export`, {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
      body: JSON.stringify({ profileId, format: "csv", from: "2026-05-31", to: "2026-05-01" }),
    });
    expect(res.status).toBe(400);
    expect(((await res.json()) as any).error.code).toBe("VALIDATION_FAILED");
  });

  it("rejects accountant format without toEmail with 400", async () => {
    const { userId, accessToken } = await seedAuthed();
    const { profileId } = await seedProfileData(userId);
    const res = await SELF.fetch(`${BASE}/export`, {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
      body: JSON.stringify({ profileId, format: "accountant", from: "2026-05-01", to: "2026-05-31" }),
    });
    expect(res.status).toBe(400);
    expect(((await res.json()) as any).error.code).toBe("VALIDATION_FAILED");
  });

  it("accountant -> emails the pack, logs email_outbox queued->sent, returns { status, outboxId }", async () => {
    const sendSpy = vi.spyOn(emailModule, "sendExportEmail").mockResolvedValue(undefined);
    const { userId, accessToken, email } = await seedAuthed();
    const { profileId } = await seedProfileData(userId);
    const res = await SELF.fetch(`${BASE}/export`, {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
      body: JSON.stringify({ profileId, format: "accountant", from: "2026-05-01", to: "2026-05-31", toEmail: "cpa@example.com" }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { status: string; outboxId: string };
    expect(body.status).toBe("sent");
    expect(typeof body.outboxId).toBe("string");

    // sendExportEmail called with BOTH attachments + the user's reply-to.
    expect(sendSpy).toHaveBeenCalledTimes(1);
    const arg = sendSpy.mock.calls[0]![1] as emailModule.ExportEmail;
    expect(arg.to).toBe("cpa@example.com");
    expect(arg.replyTo).toBe(email);
    expect(typeof arg.csv).toBe("string");
    expect(arg.csv.length).toBeGreaterThan(0);
    expect(arg.pdf.byteLength).toBeGreaterThan(0);

    // email_outbox row transitioned queued -> sent.
    const row = await env.DB.prepare(`SELECT status, kind, to_email, sent_at FROM email_outbox WHERE id = ?`)
      .bind(body.outboxId).first<{ status: string; kind: string; to_email: string; sent_at: number | null }>();
    expect(row?.status).toBe("sent");
    expect(row?.kind).toBe("export_accountant");
    expect(row?.to_email).toBe("cpa@example.com");
    expect(row?.sent_at).not.toBeNull();
  });
});

describe("GET /export/dl/:token", () => {
  it("streams the CSV for a valid token", async () => {
    const { userId, accessToken } = await seedAuthed();
    const { profileId } = await seedProfileData(userId);
    const post = await SELF.fetch(`${BASE}/export`, {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
      body: JSON.stringify({ profileId, format: "csv", from: "2026-05-01", to: "2026-05-31" }),
    });
    const { url } = (await post.json()) as { url: string };
    const dl = await SELF.fetch(url); // no auth header — public route
    expect(dl.status).toBe(200);
    expect(dl.headers.get("content-type")).toContain("text/csv");
    const text = await dl.text();
    expect(text).toContain("date,merchant,category,amount_incl_gst");
  });

  it("returns 403 for a forged token", async () => {
    const res = await SELF.fetch(`${BASE}/export/dl/not.a.valid.token`);
    expect(res.status).toBe(403);
  });

  it("returns 403 for an expired token", async () => {
    // Mint an already-expired token for some plausible key (signed with the test key).
    const { signDownloadToken } = await import("../src/lib/exportToken");
    const token = await signDownloadToken(env.JWT_SIGNING_KEY, "u/x/exports/y.csv", -10);
    const res = await SELF.fetch(`${BASE}/export/dl/${token}`);
    expect(res.status).toBe(403);
  });

  // Sanity: confirm the token issued by the route verifies under the test key.
  it("issues a token verifiable with the same signing key", async () => {
    const { userId, accessToken } = await seedAuthed();
    const { profileId } = await seedProfileData(userId);
    const post = await SELF.fetch(`${BASE}/export`, {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
      body: JSON.stringify({ profileId, format: "csv", from: "2026-05-01", to: "2026-05-31" }),
    });
    const { url } = (await post.json()) as { url: string };
    const token = url.slice(url.lastIndexOf("/") + 1);
    const out = await verifyDownloadToken(env.JWT_SIGNING_KEY, token);
    expect(out.r2Key).toContain(`${userId}/exports/`);
    expect(out.r2Key.endsWith(".csv")).toBe(true);
  });
});
