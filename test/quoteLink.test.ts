import { env, SELF, applyD1Migrations } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { issueSession } from "../src/lib/sessions";
import { signQuoteLinkToken } from "../src/lib/exportToken";

declare module "cloudflare:test" {
  interface ProvidedEnv {
    TEST_MIGRATIONS: Parameters<typeof applyD1Migrations>[1];
  }
}

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

beforeEach(async () => {
  await env.DB.exec("DELETE FROM quote_line_items");
  await env.DB.exec("DELETE FROM quotes");
  await env.DB.exec("DELETE FROM profiles");
  await env.DB.exec("DELETE FROM sessions");
  await env.DB.exec("DELETE FROM devices");
  await env.DB.exec("DELETE FROM users");
});

const BASE = "https://api.test";

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
  return { userId, accessToken };
}

/** Seed a business profile (15% GST + bank details) + a quote (gst_rate_bp snapshot) + 1 line item.
 *  When opts.logoContentType is set, an R2 logo object is stored with that content-type and
 *  the profile's logo_r2_key is set, so GET /q inlines it as a data-URI. */
async function seedQuote(
  userId: string,
  opts: { gstRateBp?: number | null; bankDetails?: string | null; logoContentType?: string } = {},
) {
  const profileId = uuidv7();
  const quoteId = uuidv7();
  const now = nowMs();
  let logoKey: string | null = null;
  if (opts.logoContentType) {
    logoKey = `${userId}/profiles/${profileId}/logo`;
    // JPEG (JFIF) magic bytes — content-type is what matters for the data-URI MIME.
    await env.RECEIPTS.put(logoKey, new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10]), {
      httpMetadata: { contentType: opts.logoContentType },
    });
  }
  await env.DB.prepare(
    `INSERT INTO profiles (id,user_id,name,type,abn,gst_registered,accent_1,accent_2,accent_3,business_email,phone,website,address,bank_details,logo_r2_key,created_at,updated_at)
     VALUES (?,?,'Acme Pty Ltd','business','12 345 678 901',1,'#0E7C72','#DCF0ED','#0A5950','hi@acme.example','0400 000 000','https://acme.example','1 Main St',?,?,?,?)`,
  ).bind(profileId, userId, opts.bankDetails === undefined ? "BSB 062-000 Acc 1234 5678" : opts.bankDetails, logoKey, now, now).run();
  await env.DB.prepare(
    `INSERT INTO quotes (id,user_id,profile_id,number,client_name,client_email,gst_enabled,gst_inclusive,gst_rate_bp,status,valid_until,created_at,updated_at)
     VALUES (?,?,?,'SN-0001','Jane Roe','jane@example.com',1,0,?, 'draft','2026-07-04',?,?)`,
  ).bind(quoteId, userId, profileId, opts.gstRateBp === undefined ? 1500 : opts.gstRateBp, now, now).run();
  await env.DB.prepare(
    `INSERT INTO quote_line_items (id,user_id,quote_id,description,quantity,unit_price_cents,sort_order,created_at,updated_at)
     VALUES (?,?,?,'Site inspection',1,10000,0,?,?)`,
  ).bind(uuidv7(), userId, quoteId, now, now).run();
  return { profileId, quoteId };
}

describe("POST /quotes/:id/link", () => {
  it("mints a token, mints a quote number if absent, and returns {url, number}", async () => {
    const { userId, accessToken } = await seedAuthed();
    const { quoteId } = await seedQuote(userId);
    const res = await SELF.fetch(`${BASE}/quotes/${quoteId}/link`, {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
      body: "{}",
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;
    expect(typeof body.url).toBe("string");
    expect(body.url).toContain("https://api.snapceipt.cc/q/");
    expect(typeof body.number).toBe("string");
    expect(body.number).toMatch(/^SN-\d{4}$/);
  });

  it("404 for a quote owned by another user", async () => {
    const { accessToken } = await seedAuthed();
    const other = await seedAuthed();
    const { quoteId } = await seedQuote(other.userId);
    const res = await SELF.fetch(`${BASE}/quotes/${quoteId}/link`, {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
      body: "{}",
    });
    expect(res.status).toBe(404);
  });

  it("400 for a quote with no line items", async () => {
    const { userId, accessToken } = await seedAuthed();
    const profileId = uuidv7();
    const quoteId = uuidv7();
    const now = nowMs();
    await env.DB.prepare(
      `INSERT INTO profiles (id,user_id,name,type,accent_1,accent_2,accent_3,created_at,updated_at)
       VALUES (?,?,'Acme','business','#0E7C72','#DCF0ED','#0A5950',?,?)`,
    ).bind(profileId, userId, now, now).run();
    await env.DB.prepare(
      `INSERT INTO quotes (id,user_id,profile_id,gst_enabled,status,created_at,updated_at)
       VALUES (?,?,?,1,'draft',?,?)`,
    ).bind(quoteId, userId, profileId, now, now).run();
    const res = await SELF.fetch(`${BASE}/quotes/${quoteId}/link`, {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
      body: "{}",
    });
    expect(res.status).toBe(400);
  });
});

describe("GET /q/:token (public HTML quote)", () => {
  it("renders the quote HTML at the document's GST rate (15%) for a valid token", async () => {
    const { userId } = await seedAuthed();
    const { quoteId } = await seedQuote(userId);
    const token = await signQuoteLinkToken(env.JWT_SIGNING_KEY, quoteId, userId);

    const res = await SELF.fetch(`${BASE}/q/${token}`); // no auth header (public)
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("text/html");
    const html = await res.text();
    expect(html).toContain("Acme Pty Ltd");
    expect(html).toContain("12 345 678 901"); // ABN
    expect(html).toContain("GST (15%)");
    expect(html).toContain("Jane Roe");
    expect(html).toContain("Payment details");
    expect(html).toContain("Made with Snapceipt");
    // 15% on 10000c subtotal = 1500c GST, 11500c total.
    expect(html).toContain("$115.00");
  });

  it("labels GST 10% when the quote's gst_rate_bp is null (pre-feature quote)", async () => {
    const { userId } = await seedAuthed();
    const { quoteId } = await seedQuote(userId, { gstRateBp: null });
    const token = await signQuoteLinkToken(env.JWT_SIGNING_KEY, quoteId, userId);
    const res = await SELF.fetch(`${BASE}/q/${token}`);
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toContain("GST (10%)");
    expect(html).toContain("$110.00"); // 10% on 10000 = 11000c total
  });

  it("inlines a JPEG logo as a data:image/jpeg data-URI (content-type round-trips)", async () => {
    const { userId } = await seedAuthed();
    const { quoteId } = await seedQuote(userId, { logoContentType: "image/jpeg" });
    const token = await signQuoteLinkToken(env.JWT_SIGNING_KEY, quoteId, userId);
    const html = await (await SELF.fetch(`${BASE}/q/${token}`)).text();
    expect(html).toContain("src=\"data:image/jpeg;base64,");
    expect(html).not.toContain("data:image/png;base64,");
  });

  it("omits the payment block when the profile has no bank details", async () => {
    const { userId } = await seedAuthed();
    const { quoteId } = await seedQuote(userId, { bankDetails: null });
    const token = await signQuoteLinkToken(env.JWT_SIGNING_KEY, quoteId, userId);
    const html = await (await SELF.fetch(`${BASE}/q/${token}`)).text();
    expect(html).not.toContain("Payment details");
  });

  it("403 for a forged token", async () => {
    const res = await SELF.fetch(`${BASE}/q/not.a.valid.token`);
    expect(res.status).toBe(403);
  });

  it("403 for an expired token", async () => {
    const { userId } = await seedAuthed();
    const { quoteId } = await seedQuote(userId);
    const token = await signQuoteLinkToken(env.JWT_SIGNING_KEY, quoteId, userId, -10);
    const res = await SELF.fetch(`${BASE}/q/${token}`);
    expect(res.status).toBe(403);
  });

  it("404 for a valid token whose quote was deleted", async () => {
    const { userId } = await seedAuthed();
    const { quoteId } = await seedQuote(userId);
    const token = await signQuoteLinkToken(env.JWT_SIGNING_KEY, quoteId, userId);
    await env.DB.exec("DELETE FROM quote_line_items");
    await env.DB.exec("DELETE FROM quotes");
    const res = await SELF.fetch(`${BASE}/q/${token}`);
    expect(res.status).toBe(404);
  });
});
