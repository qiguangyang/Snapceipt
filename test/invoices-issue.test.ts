import { env, SELF, applyD1Migrations } from "cloudflare:test";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { issueSession } from "../src/lib/sessions";
import { verifyDownloadToken, signDownloadToken } from "../src/lib/exportToken";

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
  // 'pro' plan: POST /invoices/:id/issue is server-side Pro-gated, so the success-path
  // tests below must authenticate as a Pro user. (The free-403 case lives in
  // quote-invoice-pro-gate.test.ts.)
  await env.DB.prepare(
    `INSERT INTO users (id, email, email_verified, plan, created_at, updated_at)
     VALUES (?, ?, 1, 'pro', ?, ?)`,
  ).bind(userId, `${userId}@example.com`, now, now).run();
  await env.DB.prepare(
    `INSERT INTO devices (id, user_id, platform, push_enabled, created_at, updated_at)
     VALUES (?, ?, 'ios', 1, ?, ?)`,
  ).bind(deviceId, userId, now, now).run();
  const { accessToken } = await issueSession(env.DB, { userId, deviceId, signingKey: env.JWT_SIGNING_KEY });
  return { userId, deviceId, accessToken };
}

async function seedInvoice(
  userId: string,
  opts: { gstInclusive?: boolean; gstRateBp?: number | null } = {},
) {
  const profileId = uuidv7();
  const invoiceId = uuidv7();
  const now = nowMs();
  await env.DB.prepare(
    `INSERT INTO profiles (id,user_id,name,type,abn,gst_registered,accent_1,accent_2,accent_3,created_at,updated_at)
     VALUES (?,?,'Acme','business','12 345 678 901',1,'#1','#2','#3',?,?)`,
  ).bind(profileId, userId, now, now).run();
  await env.DB.prepare(
    `INSERT INTO invoices (id,user_id,profile_id,client_name,client_email,gst_enabled,gst_inclusive,gst_rate_bp,status,due_date,created_at,updated_at)
     VALUES (?,?,?,'Jane','jane@example.com',1,?,?, 'draft','2026-07-03',?,?)`,
  ).bind(
    invoiceId,
    userId,
    profileId,
    opts.gstInclusive ? 1 : 0,
    opts.gstRateBp === undefined ? null : opts.gstRateBp,
    now,
    now,
  ).run();
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

function issue(invoiceId: string, accessToken: string) {
  return SELF.fetch(`${BASE}/invoices/${invoiceId}/issue`, {
    method: "POST",
    headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
    body: "{}",
  });
}

describe("POST /invoices/:id/issue", () => {
  it("mints INV-0001, recomputes totals, sets issued + dates + pdf_r2_key", async () => {
    const { userId, accessToken } = await seedAuthed();
    const { invoiceId } = await seedInvoice(userId);

    const res = await issue(invoiceId, accessToken);
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;
    expect(body.number).toBe("INV-0001");
    expect(body.status).toBe("issued");
    expect(body.subtotalCents).toBe(105000);
    expect(body.gstCents).toBe(10500);
    expect(body.totalCents).toBe(115500);
    expect(typeof body.issueDate).toBe("string");
    expect(typeof body.issuedAt).toBe("number");
    expect(body.pdfUrl).toContain("/invoices/dl/");

    const row = await env.DB.prepare(
      `SELECT number, status, issue_date, issued_at, total_cents, pdf_r2_key FROM invoices WHERE id=?`,
    ).bind(invoiceId).first<any>();
    expect(row.number).toBe("INV-0001");
    expect(row.status).toBe("issued");
    expect(row.issue_date).not.toBeNull();
    expect(row.issued_at).not.toBeNull();
    expect(row.total_cents).toBe(115500);
    expect(row.pdf_r2_key).toBe(`${userId}/invoices/${invoiceId}.pdf`);

    // PDF downloadable.
    const dl = await SELF.fetch(body.pdfUrl);
    expect(dl.status).toBe(200);
    expect(dl.headers.get("content-type")).toContain("application/pdf");
    const token = body.pdfUrl.slice(body.pdfUrl.lastIndexOf("/") + 1);
    expect((await verifyDownloadToken(env.JWT_SIGNING_KEY, token)).r2Key)
      .toBe(`${userId}/invoices/${invoiceId}.pdf`);
  });

  it("recomputes GST-INCLUSIVE totals (total == entered sum)", async () => {
    const { userId, accessToken } = await seedAuthed();
    const { invoiceId } = await seedInvoice(userId, { gstInclusive: true });
    const body = (await (await issue(invoiceId, accessToken)).json()) as any;
    expect(body.totalCents).toBe(105000);
    expect(body.gstCents).toBe(9545);
    expect(body.subtotalCents).toBe(95455);
  });

  it("honors a 15% gst_rate_bp (1500): $1050 ex-GST → $157.50 GST → $1207.50 total", async () => {
    const { userId, accessToken } = await seedAuthed();
    const { invoiceId } = await seedInvoice(userId, { gstRateBp: 1500 });
    const body = (await (await issue(invoiceId, accessToken)).json()) as any;
    // gross = 25000 + 2*40000 = 105000c ex-GST; 15% = 15750c GST; total 120750c.
    expect(body.subtotalCents).toBe(105000);
    expect(body.gstCents).toBe(15750);
    expect(body.totalCents).toBe(120750);
    const row = await env.DB.prepare(`SELECT gst_cents, total_cents FROM invoices WHERE id=?`)
      .bind(invoiceId).first<any>();
    expect(row.gst_cents).toBe(15750);
    expect(row.total_cents).toBe(120750);
  });

  it("honors a 15% gst_rate_bp on a clean $200 ex-GST invoice → $30 GST → $230 total", async () => {
    const { userId, accessToken } = await seedAuthed();
    const profileId = uuidv7();
    const invoiceId = uuidv7();
    const now = nowMs();
    await env.DB.prepare(
      `INSERT INTO profiles (id,user_id,name,type,accent_1,accent_2,accent_3,created_at,updated_at)
       VALUES (?,?,'Acme','business','#1','#2','#3',?,?)`,
    ).bind(profileId, userId, now, now).run();
    await env.DB.prepare(
      `INSERT INTO invoices (id,user_id,profile_id,gst_enabled,gst_inclusive,gst_rate_bp,status,created_at,updated_at)
       VALUES (?,?,?,1,0,1500,'draft',?,?)`,
    ).bind(invoiceId, userId, profileId, now, now).run();
    await env.DB.prepare(
      `INSERT INTO invoice_line_items (id,user_id,invoice_id,description,quantity,unit_price_cents,sort_order,created_at,updated_at)
       VALUES (?,?,?,'Service',1,20000,0,?,?)`,
    ).bind(uuidv7(), userId, invoiceId, now, now).run();
    const body = (await (await issue(invoiceId, accessToken)).json()) as any;
    expect(body.subtotalCents).toBe(20000);
    expect(body.gstCents).toBe(3000);
    expect(body.totalCents).toBe(23000);
  });

  it("REGRESSION: a null gst_rate_bp defaults to 10% (pre-feature invoice)", async () => {
    const { userId, accessToken } = await seedAuthed();
    const { invoiceId } = await seedInvoice(userId, { gstRateBp: null });
    const body = (await (await issue(invoiceId, accessToken)).json()) as any;
    expect(body.subtotalCents).toBe(105000);
    expect(body.gstCents).toBe(10500);
    expect(body.totalCents).toBe(115500);
  });

  it("is IDEMPOTENT: a re-issue keeps INV-0001 + the original issued_at (no new mint)", async () => {
    const { userId, accessToken } = await seedAuthed();
    const { invoiceId } = await seedInvoice(userId);

    const first = (await (await issue(invoiceId, accessToken)).json()) as any;
    expect(first.number).toBe("INV-0001");
    const firstIssuedAt = (await env.DB.prepare(`SELECT issued_at FROM invoices WHERE id=?`)
      .bind(invoiceId).first<{ issued_at: number }>())!.issued_at;

    const second = (await (await issue(invoiceId, accessToken)).json()) as any;
    expect(second.number).toBe("INV-0001");

    const ctr = await env.DB.prepare(`SELECT next_seq FROM invoice_counters WHERE profile_id=(SELECT profile_id FROM invoices WHERE id=?)`)
      .bind(invoiceId).first<{ next_seq: number }>();
    expect(ctr?.next_seq).toBe(1); // advanced only once
    const afterIssuedAt = (await env.DB.prepare(`SELECT issued_at FROM invoices WHERE id=?`)
      .bind(invoiceId).first<{ issued_at: number }>())!.issued_at;
    expect(afterIssuedAt).toBe(firstIssuedAt); // unchanged
  });

  it("downstream issues for the same PROFILE get INV-0002", async () => {
    const { userId, accessToken } = await seedAuthed();
    // Two invoices under the SAME profile.
    const profileId = uuidv7();
    const now = nowMs();
    await env.DB.prepare(
      `INSERT INTO profiles (id,user_id,name,type,accent_1,accent_2,accent_3,created_at,updated_at)
       VALUES (?,?,'Acme','business','#1','#2','#3',?,?)`,
    ).bind(profileId, userId, now, now).run();
    const mk = async () => {
      const id = uuidv7();
      await env.DB.prepare(
        `INSERT INTO invoices (id,user_id,profile_id,gst_enabled,status,created_at,updated_at)
         VALUES (?,?,?,1,'draft',?,?)`,
      ).bind(id, userId, profileId, now, now).run();
      await env.DB.prepare(
        `INSERT INTO invoice_line_items (id,user_id,invoice_id,description,quantity,unit_price_cents,sort_order,created_at,updated_at)
         VALUES (?,?,?,'X',1,1000,0,?,?)`,
      ).bind(uuidv7(), userId, id, now, now).run();
      return id;
    };
    const a = await mk();
    const b = await mk();
    expect(((await (await issue(a, accessToken)).json()) as any).number).toBe("INV-0001");
    expect(((await (await issue(b, accessToken)).json()) as any).number).toBe("INV-0002");
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
    const res = await issue(invoiceId, accessToken);
    expect(res.status).toBe(400);
    expect(((await res.json()) as any).error.code).toBe("VALIDATION_FAILED");
  });

  it("404 NOT_FOUND for an unknown invoice", async () => {
    const { accessToken } = await seedAuthed();
    expect((await issue(uuidv7(), accessToken)).status).toBe(404);
  });

  it("404 NOT_FOUND for another user's invoice", async () => {
    const { accessToken } = await seedAuthed();
    const other = await seedAuthed();
    const { invoiceId } = await seedInvoice(other.userId);
    expect((await issue(invoiceId, accessToken)).status).toBe(404);
  });
});

describe("GET /invoices/dl/:token", () => {
  it("streams the invoice PDF for a valid token (public, no auth)", async () => {
    const { userId, accessToken } = await seedAuthed();
    const { invoiceId } = await seedInvoice(userId);
    const issued = (await (await issue(invoiceId, accessToken)).json()) as any;

    const dl = await SELF.fetch(issued.pdfUrl); // no auth header
    expect(dl.status).toBe(200);
    expect(dl.headers.get("content-type")).toContain("application/pdf");
    const bytes = new Uint8Array(await dl.arrayBuffer());
    expect(bytes[0]).toBe(0x25); // %
  });

  it("returns 403 for a forged token", async () => {
    expect((await SELF.fetch(`${BASE}/invoices/dl/not.a.valid.token`)).status).toBe(403);
  });

  it("returns 403 for an expired token", async () => {
    const token = await signDownloadToken(env.JWT_SIGNING_KEY, "u/invoices/y.pdf", -10);
    expect((await SELF.fetch(`${BASE}/invoices/dl/${token}`)).status).toBe(403);
  });
});
