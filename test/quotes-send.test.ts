import { env, SELF, applyD1Migrations } from "cloudflare:test";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import * as emailModule from "../src/lib/email";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { issueSession } from "../src/lib/sessions";
import { verifyDownloadToken } from "../src/lib/exportToken";

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
  await env.DB.exec("DELETE FROM quote_line_items");
  await env.DB.exec("DELETE FROM quotes");
  await env.DB.exec("DELETE FROM quote_counters");
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
  return { userId, deviceId, accessToken, email: `${userId}@example.com` };
}

/** Seed a business profile + a draft quote + 2 line items. */
async function seedQuote(userId: string, opts: { clientEmail?: string | null } = {}) {
  const profileId = uuidv7();
  const quoteId = uuidv7();
  const now = nowMs();
  await env.DB.prepare(
    `INSERT INTO profiles (id,user_id,name,type,abn,gst_registered,accent_1,accent_2,accent_3,created_at,updated_at)
     VALUES (?,?,'Acme Pty Ltd','business','12 345 678 901',1,'#0E7C72','#DCF0ED','#0A5950',?,?)`,
  ).bind(profileId, userId, now, now).run();
  await env.DB.prepare(
    `INSERT INTO quotes (id,user_id,profile_id,client_name,client_email,gst_enabled,status,valid_until,created_at,updated_at)
     VALUES (?,?,?,'Jane Roe',?,1,'draft','2026-06-15',?,?)`,
  ).bind(quoteId, userId, profileId, opts.clientEmail === undefined ? "jane@example.com" : opts.clientEmail, now, now).run();
  await env.DB.prepare(
    `INSERT INTO quote_line_items (id,user_id,quote_id,description,quantity,unit_price_cents,sort_order,created_at,updated_at)
     VALUES (?,?,?,'Site inspection',1,25000,0,?,?)`,
  ).bind(uuidv7(), userId, quoteId, now, now).run();
  await env.DB.prepare(
    `INSERT INTO quote_line_items (id,user_id,quote_id,description,quantity,unit_price_cents,sort_order,created_at,updated_at)
     VALUES (?,?,?,'Report',2,40000,1,?,?)`,
  ).bind(uuidv7(), userId, quoteId, now, now).run();
  return { profileId, quoteId };
}

function send(quoteId: string, accessToken: string) {
  return SELF.fetch(`${BASE}/quotes/${quoteId}/send`, {
    method: "POST",
    headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
    body: "{}",
  });
}

describe("POST /quotes/:id/send", () => {
  it("recomputes totals, mints SN-0001 on first send, sets status=sent + sentAt, emails (spied)", async () => {
    const spy = vi.spyOn(emailModule, "sendQuoteEmail").mockResolvedValue(undefined);
    const { userId, accessToken, email } = await seedAuthed();
    const { quoteId } = await seedQuote(userId);

    const res = await send(quoteId, accessToken);
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;

    // Recomputed totals: subtotal 25000 + 80000 = 105000; GST 10500; total 115500.
    expect(body.subtotalCents).toBe(105000);
    expect(body.gstCents).toBe(10500);
    expect(body.totalCents).toBe(115500);
    expect(body.number).toBe("SN-0001");
    expect(body.status).toBe("sent");
    expect(typeof body.sentAt).toBe("number");
    expect(typeof body.pdfUrl).toBe("string");
    expect(body.pdfUrl).toContain("/quotes/dl/");
    expect(typeof body.expiresAt).toBe("number");
    expect(body.emailed).toBe(true);

    // Persisted on the quote.
    const row = await env.DB.prepare(
      `SELECT number, status, sent_at, subtotal_cents, gst_cents, total_cents FROM quotes WHERE id=?`,
    ).bind(quoteId).first<any>();
    expect(row.number).toBe("SN-0001");
    expect(row.status).toBe("sent");
    expect(row.sent_at).not.toBeNull();
    expect(row.total_cents).toBe(115500);

    // sendQuoteEmail got the PDF + the trader's reply-to.
    expect(spy).toHaveBeenCalledTimes(1);
    const arg = spy.mock.calls[0]![1] as emailModule.QuoteEmail;
    expect(arg.to).toBe("jane@example.com");
    expect(arg.replyTo).toBe(email);
    expect(arg.quoteNumber).toBe("SN-0001");
    expect(arg.pdf.byteLength).toBeGreaterThan(0);

    // Outbox queued -> sent.
    const outbox = await env.DB.prepare(
      `SELECT kind, status, to_email, related_id, export_format FROM email_outbox WHERE related_id=?`,
    ).bind(quoteId).first<any>();
    expect(outbox.kind).toBe("quote_send");
    expect(outbox.status).toBe("sent");
    expect(outbox.to_email).toBe("jane@example.com");
    expect(outbox.export_format).toBe("pdf");
  });

  it("is IDEMPOTENT: a re-send keeps the existing number (no new mint)", async () => {
    vi.spyOn(emailModule, "sendQuoteEmail").mockResolvedValue(undefined);
    const { userId, accessToken } = await seedAuthed();
    const { quoteId } = await seedQuote(userId);

    const first = await send(quoteId, accessToken);
    const firstBody = (await first.json()) as any;
    expect(firstBody.number).toBe("SN-0001");

    const second = await send(quoteId, accessToken);
    const secondBody = (await second.json()) as any;
    expect(secondBody.number).toBe("SN-0001"); // unchanged

    // The per-user counter advanced only ONCE.
    const ctr = await env.DB.prepare(`SELECT next_seq FROM quote_counters WHERE user_id=?`)
      .bind(userId).first<{ next_seq: number }>();
    expect(ctr?.next_seq).toBe(1);
  });

  it("downstream sends for the same user get the next number (SN-0002)", async () => {
    vi.spyOn(emailModule, "sendQuoteEmail").mockResolvedValue(undefined);
    const { userId, accessToken } = await seedAuthed();
    const a = await seedQuote(userId);
    const b = await seedQuote(userId);

    const r1 = (await (await send(a.quoteId, accessToken)).json()) as any;
    const r2 = (await (await send(b.quoteId, accessToken)).json()) as any;
    expect(r1.number).toBe("SN-0001");
    expect(r2.number).toBe("SN-0002");
  });

  it("when the email send THROWS, outbox -> failed but the route still 200s with emailed:false", async () => {
    vi.spyOn(emailModule, "sendQuoteEmail").mockRejectedValue(new Error("smtp down"));
    const { userId, accessToken } = await seedAuthed();
    const { quoteId } = await seedQuote(userId);

    const res = await send(quoteId, accessToken);
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;
    expect(body.emailed).toBe(false);
    expect(body.number).toBe("SN-0001"); // number still minted, status still sent
    expect(body.status).toBe("sent");
    expect(typeof body.pdfUrl).toBe("string");

    const outbox = await env.DB.prepare(`SELECT status, error FROM email_outbox WHERE related_id=?`)
      .bind(quoteId).first<{ status: string; error: string | null }>();
    expect(outbox?.status).toBe("failed");
    expect(outbox?.error).toContain("smtp down");
  });

  it("400 VALIDATION_FAILED when the quote has no line items", async () => {
    const { userId, accessToken } = await seedAuthed();
    const profileId = uuidv7();
    const quoteId = uuidv7();
    const now = nowMs();
    await env.DB.prepare(
      `INSERT INTO profiles (id,user_id,name,type,accent_1,accent_2,accent_3,created_at,updated_at)
       VALUES (?,?,'Acme','business','#0E7C72','#DCF0ED','#0A5950',?,?)`,
    ).bind(profileId, userId, now, now).run();
    await env.DB.prepare(
      `INSERT INTO quotes (id,user_id,profile_id,client_name,client_email,gst_enabled,status,created_at,updated_at)
       VALUES (?,?,?,'Jane','jane@example.com',1,'draft',?,?)`,
    ).bind(quoteId, userId, profileId, now, now).run();

    const res = await send(quoteId, accessToken);
    expect(res.status).toBe(400);
    expect(((await res.json()) as any).error.code).toBe("VALIDATION_FAILED");
  });

  it("400 VALIDATION_FAILED when emailing is enabled but the quote has no client email — and consumes NO number / stays draft", async () => {
    const spy = vi.spyOn(emailModule, "sendQuoteEmail").mockResolvedValue(undefined);
    const { userId, accessToken } = await seedAuthed();
    const { quoteId } = await seedQuote(userId, { clientEmail: null });
    const res = await send(quoteId, accessToken);
    expect(res.status).toBe(400);
    expect(((await res.json()) as any).error.code).toBe("VALIDATION_FAILED");

    // The precondition fires BEFORE any mutation (spec §8): no email attempted, no
    // number burned, status still draft, no outbox row, the counter never advanced.
    expect(spy).not.toHaveBeenCalled();
    const row = await env.DB.prepare(`SELECT number, status, sent_at FROM quotes WHERE id=?`)
      .bind(quoteId).first<{ number: string | null; status: string; sent_at: number | null }>();
    expect(row?.number).toBeNull();
    expect(row?.status).toBe("draft");
    expect(row?.sent_at).toBeNull();
    const outbox = await env.DB.prepare(`SELECT COUNT(*) AS n FROM email_outbox WHERE related_id=?`)
      .bind(quoteId).first<{ n: number }>();
    expect(outbox?.n).toBe(0);
    const ctr = await env.DB.prepare(`SELECT next_seq FROM quote_counters WHERE user_id=?`)
      .bind(userId).first<{ next_seq: number } | null>();
    expect(ctr).toBeNull();
  });

  it("404 NOT_FOUND for an unknown quote id", async () => {
    const { accessToken } = await seedAuthed();
    const res = await send(uuidv7(), accessToken);
    expect(res.status).toBe(404);
  });

  it("404 NOT_FOUND for a quote owned by another user", async () => {
    vi.spyOn(emailModule, "sendQuoteEmail").mockResolvedValue(undefined);
    const { accessToken } = await seedAuthed();
    const other = await seedAuthed();
    const { quoteId } = await seedQuote(other.userId);
    const res = await send(quoteId, accessToken);
    expect(res.status).toBe(404);
  });
});

describe("GET /quotes/dl/:token", () => {
  it("streams the quote PDF for a valid token (public, no auth)", async () => {
    vi.spyOn(emailModule, "sendQuoteEmail").mockResolvedValue(undefined);
    const { userId, accessToken } = await seedAuthed();
    const { quoteId } = await seedQuote(userId);
    const sent = (await (await send(quoteId, accessToken)).json()) as any;

    const dl = await SELF.fetch(sent.pdfUrl); // no auth header
    expect(dl.status).toBe(200);
    expect(dl.headers.get("content-type")).toContain("application/pdf");
    const bytes = new Uint8Array(await dl.arrayBuffer());
    expect(bytes[0]).toBe(0x25); // %

    // The token verifies under the test key + points at the quote's R2 key.
    const token = sent.pdfUrl.slice(sent.pdfUrl.lastIndexOf("/") + 1);
    const out = await verifyDownloadToken(env.JWT_SIGNING_KEY, token);
    expect(out.r2Key).toBe(`${userId}/quotes/${quoteId}.pdf`);
  });

  it("returns 403 for a forged token", async () => {
    const res = await SELF.fetch(`${BASE}/quotes/dl/not.a.valid.token`);
    expect(res.status).toBe(403);
  });

  it("returns 403 for an expired token", async () => {
    const { signDownloadToken } = await import("../src/lib/exportToken");
    const token = await signDownloadToken(env.JWT_SIGNING_KEY, "u/x/quotes/y.pdf", -10);
    const res = await SELF.fetch(`${BASE}/quotes/dl/${token}`);
    expect(res.status).toBe(403);
  });
});
