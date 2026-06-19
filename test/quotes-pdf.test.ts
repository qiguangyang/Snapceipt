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
    `INSERT INTO users (id, email, email_verified, plan, created_at, updated_at)
     VALUES (?, ?, 1, 'free', ?, ?)`,
  ).bind(userId, `${userId}@example.com`, now, now).run();
  await env.DB.prepare(
    `INSERT INTO devices (id, user_id, platform, push_enabled, created_at, updated_at)
     VALUES (?, ?, 'ios', 1, ?, ?)`,
  ).bind(deviceId, userId, now, now).run();
  const { accessToken } = await issueSession(env.DB, { userId, deviceId, signingKey: env.JWT_SIGNING_KEY });
  return { userId, deviceId, accessToken };
}

async function seedQuote(userId: string) {
  const profileId = uuidv7();
  const quoteId = uuidv7();
  const now = nowMs();
  await env.DB.prepare(
    `INSERT INTO profiles (id,user_id,name,type,abn,gst_registered,accent_1,accent_2,accent_3,created_at,updated_at)
     VALUES (?,?,'Acme','business','12 345 678 901',1,'#1','#2','#3',?,?)`,
  ).bind(profileId, userId, now, now).run();
  await env.DB.prepare(
    `INSERT INTO quotes (id,user_id,profile_id,client_name,client_email,gst_enabled,gst_inclusive,status,valid_until,created_at,updated_at)
     VALUES (?,?,?,'Jane','jane@example.com',1,0,'draft','2026-06-30',?,?)`,
  ).bind(quoteId, userId, profileId, now, now).run();
  await env.DB.prepare(
    `INSERT INTO quote_line_items (id,user_id,quote_id,description,quantity,unit_price_cents,sort_order,created_at,updated_at)
     VALUES (?,?,?,'Inspection',1,25000,0,?,?)`,
  ).bind(uuidv7(), userId, quoteId, now, now).run();
  await env.DB.prepare(
    `INSERT INTO quote_line_items (id,user_id,quote_id,description,quantity,unit_price_cents,sort_order,created_at,updated_at)
     VALUES (?,?,?,'Report',2,40000,1,?,?)`,
  ).bind(uuidv7(), userId, quoteId, now, now).run();
  return { profileId, quoteId };
}

function genPdf(quoteId: string, accessToken: string) {
  return SELF.fetch(`${BASE}/quotes/${quoteId}/pdf`, {
    method: "POST",
    headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
    body: "{}",
  });
}

describe("POST /quotes/:id/pdf", () => {
  it("mints SN-0001, persists totals + pdf_r2_key, leaves status=draft, does NOT email", async () => {
    const spy = vi.spyOn(emailModule, "sendQuoteEmail").mockResolvedValue(undefined);
    const { userId, accessToken } = await seedAuthed();
    const { quoteId } = await seedQuote(userId);

    const res = await genPdf(quoteId, accessToken);
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;
    expect(body.number).toBe("SN-0001");
    expect(body.status).toBe("draft");
    expect(body.subtotalCents).toBe(105000);
    expect(body.gstCents).toBe(10500);
    expect(body.totalCents).toBe(115500);
    expect(body.pdfUrl).toContain("/quotes/dl/");
    expect(typeof body.expiresAt).toBe("number");

    // Persisted: number + totals + pdf_r2_key set; status STILL draft; sent_at null.
    const row = await env.DB.prepare(
      `SELECT number, status, sent_at, total_cents, pdf_r2_key FROM quotes WHERE id=?`,
    ).bind(quoteId).first<any>();
    expect(row.number).toBe("SN-0001");
    expect(row.status).toBe("draft");
    expect(row.sent_at).toBeNull();
    expect(row.total_cents).toBe(115500);
    expect(row.pdf_r2_key).toBe(`${userId}/quotes/${quoteId}.pdf`);

    // No email, no outbox row.
    expect(spy).not.toHaveBeenCalled();
    const outbox = await env.DB.prepare(`SELECT COUNT(*) AS n FROM email_outbox WHERE related_id=?`)
      .bind(quoteId).first<{ n: number }>();
    expect(outbox?.n).toBe(0);

    // The PDF is downloadable via the signed token.
    const dl = await SELF.fetch(body.pdfUrl);
    expect(dl.status).toBe(200);
    expect(dl.headers.get("content-type")).toContain("application/pdf");
    const token = body.pdfUrl.slice(body.pdfUrl.lastIndexOf("/") + 1);
    const out = await verifyDownloadToken(env.JWT_SIGNING_KEY, token);
    expect(out.r2Key).toBe(`${userId}/quotes/${quoteId}.pdf`);
  });

  it("does NOT re-mint a number on a second PDF build (keeps SN-0001), refreshes pdf_r2_key", async () => {
    const { userId, accessToken } = await seedAuthed();
    const { quoteId } = await seedQuote(userId);

    const first = (await (await genPdf(quoteId, accessToken)).json()) as any;
    expect(first.number).toBe("SN-0001");
    const second = (await (await genPdf(quoteId, accessToken)).json()) as any;
    expect(second.number).toBe("SN-0001");

    const ctr = await env.DB.prepare(`SELECT next_seq FROM quote_counters WHERE user_id=?`)
      .bind(userId).first<{ next_seq: number }>();
    expect(ctr?.next_seq).toBe(1); // advanced only once
  });

  it("400 VALIDATION_FAILED when the quote has no line items", async () => {
    const { userId, accessToken } = await seedAuthed();
    const profileId = uuidv7();
    const quoteId = uuidv7();
    const now = nowMs();
    await env.DB.prepare(
      `INSERT INTO profiles (id,user_id,name,type,accent_1,accent_2,accent_3,created_at,updated_at)
       VALUES (?,?,'Acme','business','#1','#2','#3',?,?)`,
    ).bind(profileId, userId, now, now).run();
    await env.DB.prepare(
      `INSERT INTO quotes (id,user_id,profile_id,client_name,gst_enabled,status,created_at,updated_at)
       VALUES (?,?,?,'Jane',1,'draft',?,?)`,
    ).bind(quoteId, userId, profileId, now, now).run();

    const res = await genPdf(quoteId, accessToken);
    expect(res.status).toBe(400);
    expect(((await res.json()) as any).error.code).toBe("VALIDATION_FAILED");
  });

  it("404 NOT_FOUND for an unknown quote", async () => {
    const { accessToken } = await seedAuthed();
    const res = await genPdf(uuidv7(), accessToken);
    expect(res.status).toBe(404);
  });

  it("404 NOT_FOUND for a quote owned by another user", async () => {
    const { accessToken } = await seedAuthed();
    const other = await seedAuthed();
    const { quoteId } = await seedQuote(other.userId);
    const res = await genPdf(quoteId, accessToken);
    expect(res.status).toBe(404);
  });
});
