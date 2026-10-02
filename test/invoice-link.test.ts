import { env, SELF, applyD1Migrations } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { issueSession } from "../src/lib/sessions";
import { signInvoiceLinkToken } from "../src/lib/exportToken";
import * as emailModule from "../src/lib/email";

declare module "cloudflare:test" {
  interface ProvidedEnv {
    TEST_MIGRATIONS: Parameters<typeof applyD1Migrations>[1];
  }
}

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

beforeEach(async () => {
  for (const t of ["payments", "invoice_line_items", "invoices", "profiles", "sessions", "devices", "users"]) {
    await env.DB.exec(`DELETE FROM ${t}`);
  }
  vi.restoreAllMocks();
});

const BASE = "https://api.test";

async function seedAuthed() {
  const userId = uuidv7();
  const deviceId = uuidv7();
  const now = nowMs();
  // 'pro' plan: POST /invoices/:id/send is server-side Pro-gated, so the success-path
  // tests below must authenticate as a Pro user.
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

/** A business profile + an issued invoice (INV-0001, due date, 15% GST) + 1 line item. */
async function seedInvoice(userId: string, opts: { clientEmail?: string | null } = {}) {
  const profileId = uuidv7();
  const invoiceId = uuidv7();
  const now = nowMs();
  await env.DB.prepare(
    `INSERT INTO profiles (id,user_id,name,type,abn,gst_registered,accent_1,accent_2,accent_3,business_email,phone,website,address,bank_details,created_at,updated_at)
     VALUES (?,?,'Acme Pty Ltd','business','12 345 678 901',1,'#0E7C72','#DCF0ED','#0A5950','hi@acme.example','0400 000 000','https://acme.example','1 Main St','BSB 062-000 Acc 1234 5678',?,?)`,
  ).bind(profileId, userId, now, now).run();
  await env.DB.prepare(
    `INSERT INTO invoices (id,user_id,profile_id,number,client_name,client_email,gst_enabled,gst_inclusive,gst_rate_bp,status,issue_date,due_date,issued_at,created_at,updated_at)
     VALUES (?,?,?,'INV-0001','Jane Roe',?,1,0,1500,'issued','2026-06-20','2026-07-04',?,?,?)`,
  ).bind(invoiceId, userId, profileId, opts.clientEmail === undefined ? "jane@example.com" : opts.clientEmail, now, now, now).run();
  await env.DB.prepare(
    `INSERT INTO invoice_line_items (id,user_id,invoice_id,description,quantity,unit_price_cents,sort_order,created_at,updated_at)
     VALUES (?,?,?,'Site inspection',1,10000,0,?,?)`,
  ).bind(uuidv7(), userId, invoiceId, now, now).run();
  return { profileId, invoiceId };
}

describe("GET /i/:token (public HTML tax invoice)", () => {
  it("renders the invoice HTML at the document's GST rate for a valid token", async () => {
    const { userId } = await seedAuthed();
    const { invoiceId } = await seedInvoice(userId);
    const token = await signInvoiceLinkToken(env.JWT_SIGNING_KEY, invoiceId, userId);

    const res = await SELF.fetch(`${BASE}/i/${token}`); // no auth header (public)
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("text/html");
    const html = await res.text();
    expect(html).toContain("TAX INVOICE");
    expect(html).toContain("Acme Pty Ltd");
    expect(html).toContain("INV-0001");
    expect(html).toContain("Jane Roe");
    expect(html).toContain("GST (15%)");
    expect(html).toContain("Payment"); // payment section + bank details
    expect(html).toContain("$115.00"); // 15% on 10000c => 11500c total
    expect(html).not.toContain("Accept");
  });

  it("reflects recorded payments as a balance due", async () => {
    const { userId } = await seedAuthed();
    const { invoiceId } = await seedInvoice(userId);
    const now = nowMs();
    await env.DB.prepare(
      `INSERT INTO payments (id,user_id,invoice_id,amount_cents,paid_on,created_at,updated_at)
       VALUES (?,?,?,5000,'2026-06-25',?,?)`,
    ).bind(uuidv7(), userId, invoiceId, now, now).run();
    const token = await signInvoiceLinkToken(env.JWT_SIGNING_KEY, invoiceId, userId);
    const html = await (await SELF.fetch(`${BASE}/i/${token}`)).text();
    expect(html).toContain("Amount paid");
    expect(html).toContain("Balance due (AUD)");
    expect(html).toContain("$65.00"); // 11500 - 5000
  });

  it("403 for a forged/garbage token", async () => {
    const res = await SELF.fetch(`${BASE}/i/not-a-real-token`);
    expect(res.status).toBe(403);
  });

  it("403 for an expired token", async () => {
    const { userId } = await seedAuthed();
    const { invoiceId } = await seedInvoice(userId);
    const token = await signInvoiceLinkToken(env.JWT_SIGNING_KEY, invoiceId, userId, 0, -10); // version 0, ttl -10s
    const res = await SELF.fetch(`${BASE}/i/${token}`);
    expect(res.status).toBe(403);
  });

  it("404 when the invoice was deleted after the link was minted", async () => {
    const { userId } = await seedAuthed();
    const { invoiceId } = await seedInvoice(userId);
    const token = await signInvoiceLinkToken(env.JWT_SIGNING_KEY, invoiceId, userId);
    await env.DB.prepare(`UPDATE invoices SET deleted_at = ? WHERE id = ?`).bind(nowMs(), invoiceId).run();
    const res = await SELF.fetch(`${BASE}/i/${token}`);
    expect(res.status).toBe(404);
  });
});

describe("POST /invoices/:id/send wires the hosted link + rich email", () => {
  it.each(["https://api.snapceipt.cc", "https://snapceipt-api-staging.techsiderau.workers.dev"])("emails a working hosted invoice and PDF on request origin %s", async (origin) => {
    const { userId, accessToken } = await seedAuthed();
    const { invoiceId } = await seedInvoice(userId);
    const spy = vi.spyOn(emailModule, "sendInvoiceEmail").mockResolvedValue(undefined);

    const res = await SELF.fetch(`${origin}/invoices/${invoiceId}/send`, {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
      body: "{}",
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;
    expect(body.emailed).toBe(true);

    expect(spy).toHaveBeenCalledTimes(1);
    const arg = spy.mock.calls[0]![1];
    expect(arg.to).toBe("jane@example.com");
    expect(arg.replyTo).toBe("hi@acme.example"); // business email
    expect(arg.invoiceNumber).toBe("INV-0001");
    expect(arg.url).toContain(`${origin}/i/`);
    const page = await SELF.fetch(arg.url);
    expect(page.status).toBe(200);
    expect(await page.text()).toContain("Acme Pty Ltd");
    expect(arg.business.name).toBe("Acme Pty Ltd");
    expect(arg.lineItems.length).toBe(1);
    expect(arg.totalCents).toBe(11500);
    expect(arg.pdf.byteLength).toBeGreaterThan(0);
  });

  it("400 (no email sent) when the invoice has no client email", async () => {
    const { userId, accessToken } = await seedAuthed();
    const { invoiceId } = await seedInvoice(userId, { clientEmail: null });
    const spy = vi.spyOn(emailModule, "sendInvoiceEmail").mockResolvedValue(undefined);
    const res = await SELF.fetch(`${BASE}/invoices/${invoiceId}/send`, {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
      body: "{}",
    });
    expect(res.status).toBe(400);
    expect(spy).not.toHaveBeenCalled();
  });
});
