import { env, SELF, applyD1Migrations } from "cloudflare:test";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import * as emailModule from "../src/lib/email";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { issueSession } from "../src/lib/sessions";

declare module "cloudflare:test" {
  interface ProvidedEnv {
    TEST_MIGRATIONS: Parameters<typeof applyD1Migrations>[1];
  }
}

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});
afterEach(() => vi.restoreAllMocks());

beforeEach(async () => {
  await env.DB.exec("DELETE FROM email_outbox");
  await env.DB.exec("DELETE FROM payments");
  await env.DB.exec("DELETE FROM invoice_line_items");
  await env.DB.exec("DELETE FROM invoices");
  await env.DB.exec("DELETE FROM invoice_counters");
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
  // 'pro' plan: POST /invoices/:id/send + /pdf are server-side Pro-gated, so the
  // success-path tests below must authenticate as a Pro user.
  await env.DB.prepare(
    `INSERT INTO users (id, email, email_verified, plan, created_at, updated_at)
     VALUES (?, ?, 1, 'pro', ?, ?)`,
  ).bind(userId, `${userId}@example.com`, now, now).run();
  await env.DB.prepare(
    `INSERT INTO devices (id, user_id, platform, push_enabled, created_at, updated_at)
     VALUES (?, ?, 'ios', 1, ?, ?)`,
  ).bind(deviceId, userId, now, now).run();
  const { accessToken } = await issueSession(env.DB, { userId, deviceId, signingKey: env.JWT_SIGNING_KEY });
  return { userId, deviceId, accessToken, email: `${userId}@example.com` };
}

async function seedInvoice(userId: string, opts: { clientEmail?: string | null; status?: string } = {}) {
  const profileId = uuidv7();
  const invoiceId = uuidv7();
  const now = nowMs();
  await env.DB.prepare(
    `INSERT INTO profiles (id,user_id,name,type,abn,gst_registered,accent_1,accent_2,accent_3,created_at,updated_at)
     VALUES (?,?,'Acme','business','12 345 678 901',1,'#1','#2','#3',?,?)`,
  ).bind(profileId, userId, now, now).run();
  await env.DB.prepare(
    `INSERT INTO invoices (id,user_id,profile_id,number,client_name,client_email,gst_enabled,gst_inclusive,status,due_date,created_at,updated_at)
     VALUES (?,?,?,'INV-0001','Jane',?,1,0,?, '2026-07-03',?,?)`,
  ).bind(invoiceId, userId, profileId,
    opts.clientEmail === undefined ? "jane@example.com" : opts.clientEmail,
    opts.status ?? "issued", now, now).run();
  await env.DB.prepare(
    `INSERT INTO invoice_line_items (id,user_id,invoice_id,description,quantity,unit_price_cents,sort_order,created_at,updated_at)
     VALUES (?,?,?,'Inspection',1,25000,0,?,?)`,
  ).bind(uuidv7(), userId, invoiceId, now, now).run();
  await env.DB.prepare(
    `INSERT INTO invoice_line_items (id,user_id,invoice_id,description,quantity,unit_price_cents,sort_order,created_at,updated_at)
     VALUES (?,?,?,'Report',2,40000,1,?,?)`,
  ).bind(uuidv7(), userId, invoiceId, now, now).run();
  return { profileId, invoiceId };
}

function send(invoiceId: string, accessToken: string) {
  return SELF.fetch(`${BASE}/invoices/${invoiceId}/send`, {
    method: "POST",
    headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
    body: "{}",
  });
}

function pdf(invoiceId: string, accessToken: string) {
  return SELF.fetch(`${BASE}/invoices/${invoiceId}/pdf`, {
    method: "POST",
    headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
    body: "{}",
  });
}

describe("POST /invoices/:id/send", () => {
  it("emails the client (spied), writes an invoice_send outbox row, returns emailed:true", async () => {
    const spy = vi.spyOn(emailModule, "sendInvoiceEmail").mockResolvedValue(undefined);
    const { userId, accessToken, email } = await seedAuthed();
    const { invoiceId } = await seedInvoice(userId);

    const res = await send(invoiceId, accessToken);
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;
    expect(body.emailed).toBe(true);
    expect(body.totalCents).toBe(115500);
    expect(body.pdfUrl).toContain("/invoices/dl/");

    expect(spy).toHaveBeenCalledTimes(1);
    const arg = spy.mock.calls[0]![1] as emailModule.InvoiceEmail;
    expect(arg.to).toBe("jane@example.com");
    expect(arg.replyTo).toBe(email);
    expect(arg.invoiceNumber).toBe("INV-0001");
    expect(arg.pdf.byteLength).toBeGreaterThan(0);

    const outbox = await env.DB.prepare(
      `SELECT kind, status, to_email, related_id, export_format FROM email_outbox WHERE related_id=?`,
    ).bind(invoiceId).first<any>();
    expect(outbox.kind).toBe("invoice_send");
    expect(outbox.status).toBe("sent");
    expect(outbox.to_email).toBe("jane@example.com");
    expect(outbox.export_format).toBe("pdf");

    // pdf_r2_key persisted.
    const row = await env.DB.prepare(`SELECT pdf_r2_key FROM invoices WHERE id=?`).bind(invoiceId).first<any>();
    expect(row.pdf_r2_key).toBe(`${userId}/invoices/${invoiceId}.pdf`);
  });

  it("when the send THROWS, outbox -> failed but the route 200s with emailed:false", async () => {
    vi.spyOn(emailModule, "sendInvoiceEmail").mockRejectedValue(new Error("smtp down"));
    const { userId, accessToken } = await seedAuthed();
    const { invoiceId } = await seedInvoice(userId);

    const res = await send(invoiceId, accessToken);
    expect(res.status).toBe(200);
    expect(((await res.json()) as any).emailed).toBe(false);

    const outbox = await env.DB.prepare(`SELECT status, error FROM email_outbox WHERE related_id=?`)
      .bind(invoiceId).first<{ status: string; error: string | null }>();
    expect(outbox?.status).toBe("failed");
    expect(outbox?.error).toContain("smtp down");
  });

  it("400 VALIDATION_FAILED + NO mutation when the invoice has no client email", async () => {
    const spy = vi.spyOn(emailModule, "sendInvoiceEmail").mockResolvedValue(undefined);
    const { userId, accessToken } = await seedAuthed();
    const { invoiceId } = await seedInvoice(userId, { clientEmail: null });
    const res = await send(invoiceId, accessToken);
    expect(res.status).toBe(400);
    expect(((await res.json()) as any).error.code).toBe("VALIDATION_FAILED");

    expect(spy).not.toHaveBeenCalled();
    const outbox = await env.DB.prepare(`SELECT COUNT(*) AS n FROM email_outbox WHERE related_id=?`)
      .bind(invoiceId).first<{ n: number }>();
    expect(outbox?.n).toBe(0);
  });

  it("400 VALIDATION_FAILED when the invoice has no line items", async () => {
    const { userId, accessToken } = await seedAuthed();
    const profileId = uuidv7();
    const invoiceId = uuidv7();
    const now = nowMs();
    await env.DB.prepare(
      `INSERT INTO profiles (id,user_id,name,type,accent_1,accent_2,accent_3,created_at,updated_at)
       VALUES (?,?,'Acme','business','#1','#2','#3',?,?)`,
    ).bind(profileId, userId, now, now).run();
    await env.DB.prepare(
      `INSERT INTO invoices (id,user_id,profile_id,client_email,gst_enabled,status,created_at,updated_at)
       VALUES (?,?,?,'jane@example.com',1,'issued',?,?)`,
    ).bind(invoiceId, userId, profileId, now, now).run();
    expect((await send(invoiceId, accessToken)).status).toBe(400);
  });

  it("404 NOT_FOUND for an unknown invoice", async () => {
    const { accessToken } = await seedAuthed();
    expect((await send(uuidv7(), accessToken)).status).toBe(404);
  });
});

describe("POST /invoices/:id/pdf", () => {
  it("(re)builds the PDF, persists pdf_r2_key + totals, no status change, no email", async () => {
    const spy = vi.spyOn(emailModule, "sendInvoiceEmail").mockResolvedValue(undefined);
    const { userId, accessToken } = await seedAuthed();
    const { invoiceId } = await seedInvoice(userId, { status: "draft" });

    const res = await pdf(invoiceId, accessToken);
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;
    expect(body.status).toBe("draft");
    expect(body.totalCents).toBe(115500);
    expect(body.pdfUrl).toContain("/invoices/dl/");

    expect(spy).not.toHaveBeenCalled();
    const outbox = await env.DB.prepare(`SELECT COUNT(*) AS n FROM email_outbox WHERE related_id=?`)
      .bind(invoiceId).first<{ n: number }>();
    expect(outbox?.n).toBe(0);

    const row = await env.DB.prepare(`SELECT status, pdf_r2_key, total_cents FROM invoices WHERE id=?`)
      .bind(invoiceId).first<any>();
    expect(row.status).toBe("draft"); // unchanged
    expect(row.pdf_r2_key).toBe(`${userId}/invoices/${invoiceId}.pdf`);
    expect(row.total_cents).toBe(115500);

    const dl = await SELF.fetch(body.pdfUrl);
    expect(dl.status).toBe(200);
    expect(dl.headers.get("content-type")).toContain("application/pdf");
  });

  it("400 VALIDATION_FAILED when the invoice has no line items", async () => {
    const { userId, accessToken } = await seedAuthed();
    const profileId = uuidv7();
    const invoiceId = uuidv7();
    const now = nowMs();
    await env.DB.prepare(
      `INSERT INTO profiles (id,user_id,name,type,accent_1,accent_2,accent_3,created_at,updated_at)
       VALUES (?,?,'Acme','business','#1','#2','#3',?,?)`,
    ).bind(profileId, userId, now, now).run();
    await env.DB.prepare(
      `INSERT INTO invoices (id,user_id,profile_id,gst_enabled,status,created_at,updated_at)
       VALUES (?,?,?,1,'draft',?,?)`,
    ).bind(invoiceId, userId, profileId, now, now).run();
    expect((await pdf(invoiceId, accessToken)).status).toBe(400);
  });

  it("404 NOT_FOUND for another user's invoice", async () => {
    const { accessToken } = await seedAuthed();
    const other = await seedAuthed();
    const { invoiceId } = await seedInvoice(other.userId);
    expect((await pdf(invoiceId, accessToken)).status).toBe(404);
  });
});

describe("/invoices through the real app", () => {
  it("requires auth (401 without a bearer token)", async () => {
    const res = await SELF.fetch(`${BASE}/invoices/some-id/issue`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{}",
    });
    expect(res.status).toBe(401);
  });

  it("GET /invoices/dl/* is public (a forged token is 403, not 401)", async () => {
    expect((await SELF.fetch(`${BASE}/invoices/dl/forged`)).status).toBe(403);
  });
});
