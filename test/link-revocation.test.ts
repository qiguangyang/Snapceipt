import { env, SELF, applyD1Migrations } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import { SignJWT } from "jose";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { issueSession } from "../src/lib/sessions";
import {
  signInvoiceLinkToken,
  signQuoteLinkToken,
  INVOICE_LINK_ISSUER,
  INVOICE_LINK_AUDIENCE,
  QUOTE_LINK_ISSUER,
  QUOTE_LINK_AUDIENCE,
} from "../src/lib/exportToken";

// L6 — public invoice/quote link revocation. Proves the link_version gate:
//   (a) a freshly-minted link works;
//   (b) after POST .../link/revoke the OLD link 403s but a newly-minted link works;
//   (c) a LEGACY token (no `v` claim) still validates for a never-revoked (link_version=0)
//       document — the backward-compat guarantee for links already in the wild;
//   (d) revoke is owner-scoped (another user cannot revoke).

declare module "cloudflare:test" {
  interface ProvidedEnv {
    TEST_MIGRATIONS: Parameters<typeof applyD1Migrations>[1];
  }
}

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

beforeEach(async () => {
  for (const t of [
    "payments", "invoice_line_items", "invoices",
    "quote_line_items", "quotes",
    "profiles", "sessions", "devices", "users",
  ]) {
    await env.DB.exec(`DELETE FROM ${t}`);
  }
});

const BASE = "https://api.test";

async function seedAuthed() {
  const userId = uuidv7();
  const deviceId = uuidv7();
  const now = nowMs();
  // 'pro' plan: link/revoke is server-side Pro-gated, so the owner must be Pro.
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

/** A business profile + an issued invoice (INV-0001, 15% GST) + 1 line item. */
async function seedInvoice(userId: string) {
  const profileId = uuidv7();
  const invoiceId = uuidv7();
  const now = nowMs();
  await env.DB.prepare(
    `INSERT INTO profiles (id,user_id,name,type,abn,gst_registered,accent_1,accent_2,accent_3,business_email,phone,website,address,bank_details,created_at,updated_at)
     VALUES (?,?,'Acme Pty Ltd','business','12 345 678 901',1,'#0E7C72','#DCF0ED','#0A5950','hi@acme.example','0400 000 000','https://acme.example','1 Main St','BSB 062-000 Acc 1234 5678',?,?)`,
  ).bind(profileId, userId, now, now).run();
  await env.DB.prepare(
    `INSERT INTO invoices (id,user_id,profile_id,number,client_name,client_email,gst_enabled,gst_inclusive,gst_rate_bp,status,issue_date,due_date,issued_at,created_at,updated_at)
     VALUES (?,?,?,'INV-0001','Jane Roe','jane@example.com',1,0,1500,'issued','2026-06-20','2026-07-04',?,?,?)`,
  ).bind(invoiceId, userId, profileId, now, now, now).run();
  await env.DB.prepare(
    `INSERT INTO invoice_line_items (id,user_id,invoice_id,description,quantity,unit_price_cents,sort_order,created_at,updated_at)
     VALUES (?,?,?,'Site inspection',1,10000,0,?,?)`,
  ).bind(uuidv7(), userId, invoiceId, now, now).run();
  return { profileId, invoiceId };
}

/** A business profile + a quote (SN-0001, 15% GST) + 1 line item. */
async function seedQuote(userId: string) {
  const profileId = uuidv7();
  const quoteId = uuidv7();
  const now = nowMs();
  await env.DB.prepare(
    `INSERT INTO profiles (id,user_id,name,type,abn,gst_registered,accent_1,accent_2,accent_3,business_email,phone,website,address,bank_details,created_at,updated_at)
     VALUES (?,?,'Acme Pty Ltd','business','12 345 678 901',1,'#0E7C72','#DCF0ED','#0A5950','hi@acme.example','0400 000 000','https://acme.example','1 Main St','BSB 062-000 Acc 1234 5678',?,?)`,
  ).bind(profileId, userId, now, now).run();
  await env.DB.prepare(
    `INSERT INTO quotes (id,user_id,profile_id,number,client_name,client_email,gst_enabled,gst_inclusive,gst_rate_bp,status,valid_until,created_at,updated_at)
     VALUES (?,?,?,'SN-0001','Jane Roe','jane@example.com',1,0,1500,'draft','2026-07-04',?,?)`,
  ).bind(quoteId, userId, profileId, now, now).run();
  await env.DB.prepare(
    `INSERT INTO quote_line_items (id,user_id,quote_id,description,quantity,unit_price_cents,sort_order,created_at,updated_at)
     VALUES (?,?,?,'Site inspection',1,10000,0,?,?)`,
  ).bind(uuidv7(), userId, quoteId, now, now).run();
  return { profileId, quoteId };
}

/** Mint a LEGACY link token (the pre-L6 format: iid/uid or qid/uid, NO `v` claim) the exact
 *  way the old server did, so we can prove an already-in-the-wild link still validates. */
async function signLegacyInvoiceToken(invoiceId: string, userId: string): Promise<string> {
  return new SignJWT({ iid: invoiceId, uid: userId })
    .setProtectedHeader({ alg: "HS256", typ: "JWT" })
    .setIssuer(INVOICE_LINK_ISSUER)
    .setAudience(INVOICE_LINK_AUDIENCE)
    .setIssuedAt()
    .setExpirationTime("30d")
    .sign(new TextEncoder().encode(env.JWT_SIGNING_KEY));
}
async function signLegacyQuoteToken(quoteId: string, userId: string): Promise<string> {
  return new SignJWT({ qid: quoteId, uid: userId })
    .setProtectedHeader({ alg: "HS256", typ: "JWT" })
    .setIssuer(QUOTE_LINK_ISSUER)
    .setAudience(QUOTE_LINK_AUDIENCE)
    .setIssuedAt()
    .setExpirationTime("30d")
    .sign(new TextEncoder().encode(env.JWT_SIGNING_KEY));
}

describe("L6 invoice link revocation (POST /invoices/:id/link/revoke + /i/:token gate)", () => {
  it("(a) a freshly-minted link resolves to 200", async () => {
    const { userId } = await seedAuthed();
    const { invoiceId } = await seedInvoice(userId);
    const token = await signInvoiceLinkToken(env.JWT_SIGNING_KEY, invoiceId, userId, 0);
    expect((await SELF.fetch(`${BASE}/i/${token}`)).status).toBe(200);
  });

  it("(b) after revoke the OLD link 403s, but a newly-minted link works", async () => {
    const { userId, accessToken } = await seedAuthed();
    const { invoiceId } = await seedInvoice(userId);
    // Mint at the current version (0) and confirm it resolves.
    const oldToken = await signInvoiceLinkToken(env.JWT_SIGNING_KEY, invoiceId, userId, 0);
    expect((await SELF.fetch(`${BASE}/i/${oldToken}`)).status).toBe(200);

    // Revoke → link_version becomes 1; the old (v0) link no longer resolves.
    const revoke = await SELF.fetch(`${BASE}/invoices/${invoiceId}/link/revoke`, {
      method: "POST", headers: { authorization: `Bearer ${accessToken}` },
    });
    expect(revoke.status).toBe(200);
    expect(((await revoke.json()) as { linkVersion: number }).linkVersion).toBe(1);
    expect((await SELF.fetch(`${BASE}/i/${oldToken}`)).status).toBe(403);

    // A freshly-minted link (v1) works again.
    const fresh = await signInvoiceLinkToken(env.JWT_SIGNING_KEY, invoiceId, userId, 1);
    expect((await SELF.fetch(`${BASE}/i/${fresh}`)).status).toBe(200);
  });

  it("(c) a LEGACY token (no `v` claim) still validates for a never-revoked invoice", async () => {
    const { userId, accessToken } = await seedAuthed();
    const { invoiceId } = await seedInvoice(userId);
    // Backward compat: a link minted before L6 (no version claim) → treated as v0 → valid
    // while link_version is still the default 0.
    const legacy = await signLegacyInvoiceToken(invoiceId, userId);
    expect((await SELF.fetch(`${BASE}/i/${legacy}`)).status).toBe(200);

    // ...and the gate still applies to it: once revoked, even the legacy link is cut off.
    await SELF.fetch(`${BASE}/invoices/${invoiceId}/link/revoke`, {
      method: "POST", headers: { authorization: `Bearer ${accessToken}` },
    });
    expect((await SELF.fetch(`${BASE}/i/${legacy}`)).status).toBe(403);
  });

  it("(d) revoke is owner-scoped: another user cannot revoke, and the owner's link survives", async () => {
    const { userId } = await seedAuthed();
    const { invoiceId } = await seedInvoice(userId);
    const token = await signInvoiceLinkToken(env.JWT_SIGNING_KEY, invoiceId, userId, 0);

    const attacker = await seedAuthed();
    const res = await SELF.fetch(`${BASE}/invoices/${invoiceId}/link/revoke`, {
      method: "POST", headers: { authorization: `Bearer ${attacker.accessToken}` },
    });
    expect(res.status).toBe(404); // not owned → 404, not 403

    // link_version untouched → the owner's original link still resolves.
    expect((await SELF.fetch(`${BASE}/i/${token}`)).status).toBe(200);
    const row = await env.DB.prepare("SELECT link_version FROM invoices WHERE id=?")
      .bind(invoiceId).first<{ link_version: number }>();
    expect(row?.link_version).toBe(0);
  });
});

describe("L6 quote link revocation backward-compat", () => {
  it("(a) a freshly-minted quote link resolves to 200", async () => {
    const { userId } = await seedAuthed();
    const { quoteId } = await seedQuote(userId);
    const token = await signQuoteLinkToken(env.JWT_SIGNING_KEY, quoteId, userId, 0);
    expect((await SELF.fetch(`${BASE}/q/${token}`)).status).toBe(200);
  });

  it("(b) after revoke the OLD quote link 403s, but a newly-minted link works", async () => {
    const { userId, accessToken } = await seedAuthed();
    const { quoteId } = await seedQuote(userId);
    const oldToken = await signQuoteLinkToken(env.JWT_SIGNING_KEY, quoteId, userId, 0);
    expect((await SELF.fetch(`${BASE}/q/${oldToken}`)).status).toBe(200);
    const revoke = await SELF.fetch(`${BASE}/quotes/${quoteId}/link/revoke`, {
      method: "POST", headers: { authorization: `Bearer ${accessToken}` },
    });
    expect(revoke.status).toBe(200);
    expect((await SELF.fetch(`${BASE}/q/${oldToken}`)).status).toBe(403);
    const fresh = await signQuoteLinkToken(env.JWT_SIGNING_KEY, quoteId, userId, 1);
    expect((await SELF.fetch(`${BASE}/q/${fresh}`)).status).toBe(200);
  });

  it("(c) a LEGACY quote token (no `v` claim) still validates for a never-revoked quote", async () => {
    const { userId } = await seedAuthed();
    const { quoteId } = await seedQuote(userId);
    const legacy = await signLegacyQuoteToken(quoteId, userId);
    expect((await SELF.fetch(`${BASE}/q/${legacy}`)).status).toBe(200);
  });

  it("(d) quote revoke is owner-scoped: another user cannot revoke", async () => {
    const { userId } = await seedAuthed();
    const { quoteId } = await seedQuote(userId);
    const attacker = await seedAuthed();
    const res = await SELF.fetch(`${BASE}/quotes/${quoteId}/link/revoke`, {
      method: "POST", headers: { authorization: `Bearer ${attacker.accessToken}` },
    });
    expect(res.status).toBe(404);
  });
});
