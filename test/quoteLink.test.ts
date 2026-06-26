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
  // 'pro' plan: POST /quotes/:id/link + /link/revoke are server-side Pro-gated, so the
  // success-path tests below must authenticate as a Pro user.
  await env.DB.prepare(
    `INSERT INTO users (id, email, email_verified, display_name, plan, created_at, updated_at)
     VALUES (?, ?, 1, 'Dev', 'pro', ?, ?)`,
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

  it("e2e: renders ALL business + bank details in full (not truncated/missing)", async () => {
    const { userId } = await seedAuthed();
    const { quoteId } = await seedQuote(userId);
    const token = await signQuoteLinkToken(env.JWT_SIGNING_KEY, quoteId, userId);
    const res = await SELF.fetch(`${BASE}/q/${token}`);
    expect(res.status).toBe(200);
    const html = await res.text();

    // Business header — every contact field present and FULL (the reported bug was the
    // email rendering as a single char and the other fields missing entirely).
    expect(html).toContain("Acme Pty Ltd");          // name
    expect(html).toContain("hi@acme.example");        // FULL business email
    expect(html).toContain("0400 000 000");           // phone
    expect(html).toContain("acme.example");           // website
    expect(html).toContain("1 Main St");              // address
    expect(html).toContain("12 345 678 901");         // ABN
    // Bank / payment details (the value, not just the heading).
    expect(html).toContain("Payment details");
    expect(html).toContain("BSB 062-000 Acc 1234 5678");
    // Client + line item + total.
    expect(html).toContain("Jane Roe");
    expect(html).toContain("jane@example.com");
    expect(html).toContain("Site inspection");
    expect(html).toContain("$115.00");
  });

  it("e2e: renders a long business email in full (no single-char truncation)", async () => {
    const { userId } = await seedAuthed();
    const profileId = uuidv7();
    const quoteId = uuidv7();
    const now = nowMs();
    await env.DB.prepare(
      `INSERT INTO profiles (id,user_id,name,type,accent_1,accent_2,accent_3,business_email,created_at,updated_at)
       VALUES (?,?,'Long Co','business','#0E7C72','#DCF0ED','#0A5950','accounts.payable@longcompanyname.com.au',?,?)`,
    ).bind(profileId, userId, now, now).run();
    await env.DB.prepare(
      `INSERT INTO quotes (id,user_id,profile_id,number,client_name,gst_enabled,gst_inclusive,gst_rate_bp,status,created_at,updated_at)
       VALUES (?,?,?,'SN-0002','Bob',1,0,1000,'draft',?,?)`,
    ).bind(quoteId, userId, profileId, now, now).run();
    await env.DB.prepare(
      `INSERT INTO quote_line_items (id,user_id,quote_id,description,quantity,unit_price_cents,sort_order,created_at,updated_at)
       VALUES (?,?,?,'Work',1,5000,0,?,?)`,
    ).bind(uuidv7(), userId, quoteId, now, now).run();
    const token = await signQuoteLinkToken(env.JWT_SIGNING_KEY, quoteId, userId);
    const res = await SELF.fetch(`${BASE}/q/${token}`);
    const html = await res.text();
    expect(html).toContain("accounts.payable@longcompanyname.com.au");
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
    const token = await signQuoteLinkToken(env.JWT_SIGNING_KEY, quoteId, userId, 0, -10); // version 0, ttl -10s
    const res = await SELF.fetch(`${BASE}/q/${token}`);
    expect(res.status).toBe(403);
  });

  it("403 once the quote link is revoked (link_version bumped past the token)", async () => {
    const { userId, accessToken } = await seedAuthed();
    const { quoteId } = await seedQuote(userId);
    // Mint a link at the current version (0) and confirm it works.
    const token = await signQuoteLinkToken(env.JWT_SIGNING_KEY, quoteId, userId, 0);
    expect((await SELF.fetch(`${BASE}/q/${token}`)).status).toBe(200);

    // Revoke → link_version becomes 1; the old (v0) link no longer resolves.
    const revoke = await SELF.fetch(`${BASE}/quotes/${quoteId}/link/revoke`, {
      method: "POST", headers: { authorization: `Bearer ${accessToken}` },
    });
    expect(revoke.status).toBe(200);
    expect(((await revoke.json()) as { linkVersion: number }).linkVersion).toBe(1);
    expect((await SELF.fetch(`${BASE}/q/${token}`)).status).toBe(403);

    // A freshly-minted link (v1) works again.
    const fresh = await signQuoteLinkToken(env.JWT_SIGNING_KEY, quoteId, userId, 1);
    expect((await SELF.fetch(`${BASE}/q/${fresh}`)).status).toBe(200);
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

  it("renders the Accept button + accept script for a valid (non-accepted) token", async () => {
    const { userId } = await seedAuthed();
    const { quoteId } = await seedQuote(userId);
    const token = await signQuoteLinkToken(env.JWT_SIGNING_KEY, quoteId, userId);
    const html = await (await SELF.fetch(`${BASE}/q/${token}`)).text();
    expect(html).toContain("Accept quote");
    expect(html).toContain("Save as PDF");
    expect(html).toContain(`/q/${token}/accept`);
    expect(html).toContain("Powered by Snapceipt");
  });

  it("shows the Accepted banner (no Accept button) once the quote is accepted", async () => {
    const { userId } = await seedAuthed();
    const { quoteId } = await seedQuote(userId);
    await env.DB.prepare("UPDATE quotes SET status='accepted' WHERE id=?").bind(quoteId).run();
    const token = await signQuoteLinkToken(env.JWT_SIGNING_KEY, quoteId, userId);
    const html = await (await SELF.fetch(`${BASE}/q/${token}`)).text();
    expect(html).not.toContain(">Accept quote<");
    expect(html).toContain("Accepted");
    expect(html).toContain("Save as PDF"); // PDF button still present
  });
});

describe("POST /q/:token/accept (public accept)", () => {
  it("valid token → sets status=accepted, bumps rev, returns {ok, status}", async () => {
    const { userId } = await seedAuthed();
    const { quoteId } = await seedQuote(userId);
    const revBefore = (await env.DB.prepare("SELECT rev FROM quotes WHERE id=?")
      .bind(quoteId).first<{ rev: number }>())!.rev;
    const token = await signQuoteLinkToken(env.JWT_SIGNING_KEY, quoteId, userId);

    const res = await SELF.fetch(`${BASE}/q/${token}/accept`, { method: "POST" }); // no auth (public)
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true, status: "accepted" });

    const row = await env.DB.prepare("SELECT status, rev FROM quotes WHERE id=?")
      .bind(quoteId).first<{ status: string; rev: number }>();
    expect(row?.status).toBe("accepted");
    expect(row?.rev).toBe(revBefore + 1);
  });

  it("is IDEMPOTENT: a second accept stays ok and does NOT re-bump rev", async () => {
    const { userId } = await seedAuthed();
    const { quoteId } = await seedQuote(userId);
    const token = await signQuoteLinkToken(env.JWT_SIGNING_KEY, quoteId, userId);

    await SELF.fetch(`${BASE}/q/${token}/accept`, { method: "POST" });
    const revAfterFirst = (await env.DB.prepare("SELECT rev FROM quotes WHERE id=?")
      .bind(quoteId).first<{ rev: number }>())!.rev;

    const res2 = await SELF.fetch(`${BASE}/q/${token}/accept`, { method: "POST" });
    expect(res2.status).toBe(200);
    expect(await res2.json()).toEqual({ ok: true, status: "accepted" });

    const row = await env.DB.prepare("SELECT status, rev FROM quotes WHERE id=?")
      .bind(quoteId).first<{ status: string; rev: number }>();
    expect(row?.status).toBe("accepted");
    expect(row?.rev).toBe(revAfterFirst); // unchanged on the idempotent re-accept
  });

  it("403 for a forged token (no status change)", async () => {
    const res = await SELF.fetch(`${BASE}/q/not.a.valid.token/accept`, { method: "POST" });
    expect(res.status).toBe(403);
  });

  it("403 for an expired token", async () => {
    const { userId } = await seedAuthed();
    const { quoteId } = await seedQuote(userId);
    const token = await signQuoteLinkToken(env.JWT_SIGNING_KEY, quoteId, userId, 0, -10); // expired
    const res = await SELF.fetch(`${BASE}/q/${token}/accept`, { method: "POST" });
    expect(res.status).toBe(403);
    const row = await env.DB.prepare("SELECT status FROM quotes WHERE id=?")
      .bind(quoteId).first<{ status: string }>();
    expect(row?.status).toBe("draft"); // unchanged
  });

  it("403 once the quote link is revoked (link_version bumped past the token)", async () => {
    const { userId, accessToken } = await seedAuthed();
    const { quoteId } = await seedQuote(userId);
    const token = await signQuoteLinkToken(env.JWT_SIGNING_KEY, quoteId, userId, 0);
    await SELF.fetch(`${BASE}/quotes/${quoteId}/link/revoke`, {
      method: "POST", headers: { authorization: `Bearer ${accessToken}` },
    });
    const res = await SELF.fetch(`${BASE}/q/${token}/accept`, { method: "POST" });
    expect(res.status).toBe(403);
  });
});
