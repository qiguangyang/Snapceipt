import { env, SELF, applyD1Migrations } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
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

beforeEach(async () => {
  await env.DB.exec("DELETE FROM payments");
  await env.DB.exec("DELETE FROM invoice_line_items");
  await env.DB.exec("DELETE FROM invoices");
  await env.DB.exec("DELETE FROM processed_mutations");
  await env.DB.exec("DELETE FROM profiles");
  await env.DB.exec("DELETE FROM sessions");
  await env.DB.exec("DELETE FROM devices");
  await env.DB.exec("DELETE FROM users");
});

const BASE = "https://api.test";

async function seedAuthed() {
  const userId = uuidv7();
  const deviceId = uuidv7();
  const profileId = uuidv7();
  const now = nowMs();
  await env.DB.prepare(
    `INSERT INTO users (id, email, email_verified, plan, created_at, updated_at)
     VALUES (?, ?, 1, 'free', ?, ?)`,
  ).bind(userId, `${userId}@example.com`, now, now).run();
  await env.DB.prepare(
    `INSERT INTO devices (id, user_id, platform, push_enabled, created_at, updated_at)
     VALUES (?, ?, 'ios', 1, ?, ?)`,
  ).bind(deviceId, userId, now, now).run();
  await env.DB.prepare(
    `INSERT INTO profiles (id,user_id,name,type,accent_1,accent_2,accent_3,created_at,updated_at)
     VALUES (?,?,'Acme','business','#1','#2','#3',?,?)`,
  ).bind(profileId, userId, now, now).run();
  const { accessToken } = await issueSession(env.DB, { userId, deviceId, signingKey: env.JWT_SIGNING_KEY });
  return { userId, deviceId, profileId, accessToken };
}

function push(accessToken: string, deviceId: string, mutations: unknown[]) {
  return SELF.fetch(`${BASE}/sync/push`, {
    method: "POST",
    headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
    body: JSON.stringify({ deviceId, mutations }),
  });
}

function pull(accessToken: string) {
  return SELF.fetch(`${BASE}/sync/pull?limit=500`, {
    headers: { authorization: `Bearer ${accessToken}` },
  });
}

describe("sync round-trip — invoice / invoiceLineItem / payment", () => {
  it("upserts + pulls an invoice (profile-scoped) with its camelCase envelope", async () => {
    const { userId, deviceId, profileId, accessToken } = await seedAuthed();
    const invoiceId = uuidv7();
    const now = nowMs();
    const res = await push(accessToken, deviceId, [
      {
        mutationId: uuidv7(),
        entityType: "invoice",
        entityId: invoiceId,
        op: "upsert",
        baseRev: 0,
        updatedAt: now,
        payload: {
          id: invoiceId,
          userId,
          profileId,
          type: "invoice",
          quoteId: null,
          clientName: "Jane Roe",
          clientEmail: "jane@example.com",
          gstEnabled: true,
          gstInclusive: false,
          subtotalCents: 105000,
          gstCents: 10500,
          totalCents: 115500,
          currency: "AUD",
          status: "draft",
          dueDate: "2026-07-03",
          createdAt: now,
          updatedAt: now,
          deletedAt: null,
          rev: 0,
          lastEditedDeviceId: null,
        },
      },
    ]);
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;
    expect(body.results[0].status).toBe("applied");

    // Persisted in D1 with snake_case columns.
    const row = await env.DB.prepare(
      `SELECT profile_id, client_name, total_cents, status, due_date FROM invoices WHERE id=?`,
    ).bind(invoiceId).first<any>();
    expect(row.profile_id).toBe(profileId);
    expect(row.client_name).toBe("Jane Roe");
    expect(row.total_cents).toBe(115500);
    expect(row.status).toBe("draft");
    expect(row.due_date).toBe("2026-07-03");

    // Pull echoes the camelCase envelope.
    const pulled = (await (await pull(accessToken)).json()) as any;
    const inv = pulled.changes.find((ch: any) => ch.type === "invoice" && ch.id === invoiceId);
    expect(inv).toBeTruthy();
    expect(inv.profileId).toBe(profileId);
    expect(inv.clientName).toBe("Jane Roe");
    expect(inv.totalCents).toBe(115500);
    expect(inv.gstEnabled).toBe(1); // booleans persist as 0/1
  });

  it("upserts an invoiceLineItem (itemDescription -> description) and a payment", async () => {
    const { userId, deviceId, accessToken } = await seedAuthed();
    const invoiceId = uuidv7();
    const liId = uuidv7();
    const payId = uuidv7();
    const now = nowMs();
    // Seed a parent invoice row directly so the FK on the children is satisfied.
    await env.DB.prepare(
      `INSERT INTO invoices (id,user_id,profile_id,status,created_at,updated_at)
       VALUES (?,?,(SELECT id FROM profiles WHERE user_id=?),'draft',?,?)`,
    ).bind(invoiceId, userId, userId, now, now).run();

    const res = await push(accessToken, deviceId, [
      {
        mutationId: uuidv7(),
        entityType: "invoiceLineItem",
        entityId: liId,
        op: "upsert",
        baseRev: 0,
        updatedAt: now,
        payload: {
          id: liId,
          userId,
          type: "invoiceLineItem",
          invoiceId,
          itemDescription: "Site inspection",
          quantity: 1,
          unitPriceCents: 25000,
          sortOrder: 0,
          createdAt: now,
          updatedAt: now,
          deletedAt: null,
          rev: 0,
          lastEditedDeviceId: null,
        },
      },
      {
        mutationId: uuidv7(),
        entityType: "payment",
        entityId: payId,
        op: "upsert",
        baseRev: 0,
        updatedAt: now,
        payload: {
          id: payId,
          userId,
          type: "payment",
          invoiceId,
          amountCents: 50000,
          paidOn: "2026-06-20",
          method: "bank transfer",
          note: "deposit",
          createdAt: now,
          updatedAt: now,
          deletedAt: null,
          rev: 0,
          lastEditedDeviceId: null,
        },
      },
    ]);
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;
    expect(body.results.every((r: any) => r.status === "applied")).toBe(true);

    // Line item: itemDescription mapped to the description column; line_total generated.
    const li = await env.DB.prepare(
      `SELECT description, unit_price_cents, line_total_cents FROM invoice_line_items WHERE id=?`,
    ).bind(liId).first<any>();
    expect(li.description).toBe("Site inspection");
    expect(li.unit_price_cents).toBe(25000);
    expect(li.line_total_cents).toBe(25000);

    // Payment persisted.
    const pay = await env.DB.prepare(
      `SELECT amount_cents, paid_on, method FROM payments WHERE id=?`,
    ).bind(payId).first<any>();
    expect(pay.amount_cents).toBe(50000);
    expect(pay.paid_on).toBe("2026-06-20");
    expect(pay.method).toBe("bank transfer");

    // Pull echoes itemDescription back (column -> camelCase via the map).
    const pulled = (await (await pull(accessToken)).json()) as any;
    const liPulled = pulled.changes.find((ch: any) => ch.type === "invoiceLineItem" && ch.id === liId);
    expect(liPulled.itemDescription).toBe("Site inspection");
    const payPulled = pulled.changes.find((ch: any) => ch.type === "payment" && ch.id === payId);
    expect(payPulled.paidOn).toBe("2026-06-20");
  });

  it("rejects an invoice upsert that omits the required profileId", async () => {
    const { userId, deviceId, accessToken } = await seedAuthed();
    const invoiceId = uuidv7();
    const now = nowMs();
    const res = await push(accessToken, deviceId, [
      {
        mutationId: uuidv7(),
        entityType: "invoice",
        entityId: invoiceId,
        op: "upsert",
        baseRev: 0,
        updatedAt: now,
        payload: {
          id: invoiceId, userId, type: "invoice", status: "draft",
          createdAt: now, updatedAt: now, deletedAt: null, rev: 0, lastEditedDeviceId: null,
        },
      },
    ]);
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;
    expect(body.results[0].status).toBe("rejected");
    expect(body.results[0].reason).toBe("VALIDATION_FAILED");
  });
});
