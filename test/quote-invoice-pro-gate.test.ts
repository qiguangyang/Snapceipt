import { env, SELF } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as emailModule from "../src/lib/email";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { issueSession } from "../src/lib/sessions";

// The Quotes/Invoices mutating routes (send / link / link-revoke / issue / pdf) are a
// paid feature. The server must enforce Pro independently of the iOS paywall, so a
// modified free-tier client cannot bypass payment. This mirrors export-pro-gate.test.ts.

const BASE = "https://api.test";

afterEach(() => vi.restoreAllMocks());

beforeEach(async () => {
  await env.DB.exec("DELETE FROM email_outbox");
  await env.DB.exec("DELETE FROM quote_line_items");
  await env.DB.exec("DELETE FROM quotes");
  await env.DB.exec("DELETE FROM quote_counters");
  await env.DB.exec("DELETE FROM invoice_line_items");
  await env.DB.exec("DELETE FROM invoices");
  await env.DB.exec("DELETE FROM invoice_counters");
  await env.DB.exec("DELETE FROM profiles");
  await env.DB.exec("DELETE FROM sessions");
  await env.DB.exec("DELETE FROM devices");
  await env.DB.exec("DELETE FROM users");
});

/** Seed a user on the given plan + their session bearer. */
async function seedUser(plan: "free" | "pro"): Promise<{ userId: string; accessToken: string }> {
  const userId = uuidv7();
  const deviceId = uuidv7();
  const now = nowMs();
  await env.DB.prepare(
    "INSERT INTO users (id, email, email_verified, plan, created_at, updated_at) VALUES (?, ?, 1, ?, ?, ?)",
  ).bind(userId, `${userId}@example.com`, plan, now, now).run();
  const { accessToken } = await issueSession(env.DB, { userId, deviceId, signingKey: env.JWT_SIGNING_KEY });
  return { userId, accessToken };
}

/** A business profile + a draft quote (client email) + 1 line item, owned by userId. */
async function seedQuote(userId: string): Promise<string> {
  const profileId = uuidv7();
  const quoteId = uuidv7();
  const now = nowMs();
  await env.DB.prepare(
    `INSERT INTO profiles (id,user_id,name,type,abn,gst_registered,business_email,accent_1,accent_2,accent_3,created_at,updated_at)
     VALUES (?,?,'Acme Pty Ltd','business','12 345 678 901',1,'hello@acme.example','#0E7C72','#DCF0ED','#0A5950',?,?)`,
  ).bind(profileId, userId, now, now).run();
  await env.DB.prepare(
    `INSERT INTO quotes (id,user_id,profile_id,client_name,client_email,gst_enabled,gst_inclusive,gst_rate_bp,status,created_at,updated_at)
     VALUES (?,?,?,'Jane Roe','jane@example.com',1,0,1000,'draft',?,?)`,
  ).bind(quoteId, userId, profileId, now, now).run();
  await env.DB.prepare(
    `INSERT INTO quote_line_items (id,user_id,quote_id,description,quantity,unit_price_cents,sort_order,created_at,updated_at)
     VALUES (?,?,?,'Site inspection',1,25000,0,?,?)`,
  ).bind(uuidv7(), userId, quoteId, now, now).run();
  return quoteId;
}

/** A business profile + a draft invoice (client email) + 1 line item, owned by userId. */
async function seedInvoice(userId: string): Promise<string> {
  const profileId = uuidv7();
  const invoiceId = uuidv7();
  const now = nowMs();
  await env.DB.prepare(
    `INSERT INTO profiles (id,user_id,name,type,abn,gst_registered,accent_1,accent_2,accent_3,created_at,updated_at)
     VALUES (?,?,'Acme','business','12 345 678 901',1,'#1','#2','#3',?,?)`,
  ).bind(profileId, userId, now, now).run();
  await env.DB.prepare(
    `INSERT INTO invoices (id,user_id,profile_id,client_name,client_email,gst_enabled,gst_inclusive,gst_rate_bp,status,created_at,updated_at)
     VALUES (?,?,?,'Jane','jane@example.com',1,0,1000,'draft',?,?)`,
  ).bind(invoiceId, userId, profileId, now, now).run();
  await env.DB.prepare(
    `INSERT INTO invoice_line_items (id,user_id,invoice_id,description,quantity,unit_price_cents,sort_order,created_at,updated_at)
     VALUES (?,?,?,'Inspection',1,25000,0,?,?)`,
  ).bind(uuidv7(), userId, invoiceId, now, now).run();
  return invoiceId;
}

function post(path: string, accessToken: string) {
  return SELF.fetch(`${BASE}${path}`, {
    method: "POST",
    headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
    body: "{}",
  });
}

describe("POST /quotes/:id/send is Pro-gated", () => {
  it("free user (owning a valid quote) is 403 FORBIDDEN — Snapceipt Pro required", async () => {
    const spy = vi.spyOn(emailModule, "sendQuoteEmail").mockResolvedValue(undefined);
    const { userId, accessToken } = await seedUser("free");
    const quoteId = await seedQuote(userId);

    const res = await post(`/quotes/${quoteId}/send`, accessToken);
    expect(res.status).toBe(403);
    const body = (await res.json()) as { error: { code: string; message: string } };
    expect(body.error.code).toBe("FORBIDDEN");
    expect(body.error.message).toContain("Snapceipt Pro");

    // The Pro gate fires BEFORE any send/mutation: no email, quote stays draft, no number.
    expect(spy).not.toHaveBeenCalled();
    const row = await env.DB.prepare(`SELECT number, status FROM quotes WHERE id=?`)
      .bind(quoteId).first<{ number: string | null; status: string }>();
    expect(row?.number).toBeNull();
    expect(row?.status).toBe("draft");
  });

  it("pro user (owning the same quote) is NOT blocked by the Pro gate (mints the link → 200)", async () => {
    // /quotes/:id/link is email-free, so the Pro-pass needs no email spy.
    const { userId, accessToken } = await seedUser("pro");
    const quoteId = await seedQuote(userId);
    const res = await post(`/quotes/${quoteId}/link`, accessToken);
    expect(res.status).toBe(200);
  });
});

describe("POST /invoices/:id/issue is Pro-gated", () => {
  it("free user (owning a valid invoice) is 403 FORBIDDEN — Snapceipt Pro required", async () => {
    const { userId, accessToken } = await seedUser("free");
    const invoiceId = await seedInvoice(userId);

    const res = await post(`/invoices/${invoiceId}/issue`, accessToken);
    expect(res.status).toBe(403);
    const body = (await res.json()) as { error: { code: string; message: string } };
    expect(body.error.code).toBe("FORBIDDEN");
    expect(body.error.message).toContain("Snapceipt Pro");

    // The Pro gate fires BEFORE the number mint / PDF build: invoice stays draft, no number.
    const row = await env.DB.prepare(`SELECT number, status FROM invoices WHERE id=?`)
      .bind(invoiceId).first<{ number: string | null; status: string }>();
    expect(row?.number).toBeNull();
    expect(row?.status).toBe("draft");
  });

  it("pro user (owning the same invoice) is NOT blocked by the Pro gate (issues → 200)", async () => {
    const { userId, accessToken } = await seedUser("pro");
    const invoiceId = await seedInvoice(userId);
    const res = await post(`/invoices/${invoiceId}/issue`, accessToken);
    expect(res.status).toBe(200);
  });
});
