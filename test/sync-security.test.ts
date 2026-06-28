import { env, SELF, applyD1Migrations } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { issueSession } from "../src/lib/sessions";

/**
 * Regression coverage for the two /sync/push hardening fixes:
 *   M2 — per-entity numeric validation (no stored markup in numeric columns).
 *   L4 — child-entity parent ownership (no cross-tenant parent attach).
 * See src/routes/sync.ts (guards 5c + 5d) and the backend security audit.
 */

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

/** Create a fully-authed user (user + device + profile + live session). */
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
  const { accessToken } = await issueSession(env.DB, {
    userId,
    deviceId,
    signingKey: env.JWT_SIGNING_KEY,
  });
  return { userId, deviceId, profileId, accessToken };
}

/** Seed an invoice row owned by `userId` and return its id (a valid child parent). */
async function seedInvoice(userId: string) {
  const invoiceId = uuidv7();
  const now = nowMs();
  await env.DB.prepare(
    `INSERT INTO invoices (id,user_id,profile_id,status,created_at,updated_at)
     VALUES (?,?,(SELECT id FROM profiles WHERE user_id=?),'draft',?,?)`,
  ).bind(invoiceId, userId, userId, now, now).run();
  return invoiceId;
}

function push(accessToken: string, deviceId: string, mutations: unknown[]) {
  return SELF.fetch(`${BASE}/sync/push`, {
    method: "POST",
    headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
    body: JSON.stringify({ deviceId, mutations }),
  });
}

/** A line-item mutation against `invoiceId` with overridable payload fields. */
function lineItemMutation(
  userId: string,
  invoiceId: string,
  payloadOverrides: Record<string, unknown> = {},
) {
  const id = uuidv7();
  const now = nowMs();
  return {
    mutationId: uuidv7(),
    entityType: "invoiceLineItem",
    entityId: id,
    op: "upsert" as const,
    baseRev: 0,
    updatedAt: now,
    payload: {
      id,
      userId,
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
      ...payloadOverrides,
    } as Record<string, unknown>,
  };
}

describe("M2 — /sync/push rejects markup in numeric columns (stored-XSS sink)", () => {
  it("rejects a non-numeric quantity (HTML markup) — VALIDATION_FAILED, nothing stored", async () => {
    const { userId, deviceId, accessToken } = await seedAuthed();
    const invoiceId = await seedInvoice(userId); // own parent so only the M2 guard can fire
    const m = lineItemMutation(userId, invoiceId, {
      quantity: "<img src=x onerror=alert(1)>",
    });

    const res = await push(accessToken, deviceId, [m]);
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;
    expect(body.error).toBeUndefined();
    expect(body.results[0].status).toBe("rejected");
    expect(body.results[0].reason).toBe("VALIDATION_FAILED");

    // The raw markup was NOT persisted in the numeric column.
    const row = await env.DB.prepare(
      `SELECT quantity FROM invoice_line_items WHERE id=?`,
    ).bind(m.entityId).first<any>();
    expect(row).toBeNull();
  });

  it("rejects a non-numeric unitPriceCents (a *_cents money column)", async () => {
    const { userId, deviceId, accessToken } = await seedAuthed();
    const invoiceId = await seedInvoice(userId);
    const m = lineItemMutation(userId, invoiceId, {
      unitPriceCents: "<script>alert(1)</script>",
    });

    const body = (await (await push(accessToken, deviceId, [m])).json()) as any;
    expect(body.results[0].status).toBe("rejected");
    expect(body.results[0].reason).toBe("VALIDATION_FAILED");
    const row = await env.DB.prepare(
      `SELECT id FROM invoice_line_items WHERE id=?`,
    ).bind(m.entityId).first<any>();
    expect(row).toBeNull();
  });

  it("still applies a valid integer line item (no false positive)", async () => {
    const { userId, deviceId, accessToken } = await seedAuthed();
    const invoiceId = await seedInvoice(userId);
    const m = lineItemMutation(userId, invoiceId, { quantity: 3, unitPriceCents: 12345 });

    const body = (await (await push(accessToken, deviceId, [m])).json()) as any;
    expect(body.results[0].status).toBe("applied");
    const row = await env.DB.prepare(
      `SELECT quantity, unit_price_cents FROM invoice_line_items WHERE id=?`,
    ).bind(m.entityId).first<any>();
    expect(row.quantity).toBe(3);
    expect(row.unit_price_cents).toBe(12345);
  });
});

describe("L4 — /sync/push child parent ownership (cross-tenant attach)", () => {
  it("rejects a child whose parent invoice belongs to ANOTHER user (FORBIDDEN)", async () => {
    const attacker = await seedAuthed();
    const victim = await seedAuthed();
    // Parent invoice owned by the victim; the attacker's auth references it.
    const victimInvoiceId = await seedInvoice(victim.userId);

    const m = lineItemMutation(attacker.userId, victimInvoiceId);
    const body = (await (await push(attacker.accessToken, attacker.deviceId, [m])).json()) as any;
    expect(body.results[0].status).toBe("rejected");
    expect(body.results[0].reason).toBe("FORBIDDEN");

    // No child row was attached to the victim's invoice.
    const row = await env.DB.prepare(
      `SELECT id FROM invoice_line_items WHERE id=?`,
    ).bind(m.entityId).first<any>();
    expect(row).toBeNull();
  });

  it("accepts a child whose parent invoice belongs to the caller", async () => {
    const { userId, deviceId, accessToken } = await seedAuthed();
    const ownInvoiceId = await seedInvoice(userId);

    const m = lineItemMutation(userId, ownInvoiceId);
    const body = (await (await push(accessToken, deviceId, [m])).json()) as any;
    expect(body.results[0].status).toBe("applied");
    const row = await env.DB.prepare(
      `SELECT invoice_id FROM invoice_line_items WHERE id=?`,
    ).bind(m.entityId).first<any>();
    expect(row.invoice_id).toBe(ownInvoiceId);
  });

  it("does not FORBID a child whose parent is absent (out-of-order sync allowed by L4)", async () => {
    const { userId, deviceId, accessToken } = await seedAuthed();
    const absentInvoiceId = uuidv7(); // never synced/seeded

    const m = lineItemMutation(userId, absentInvoiceId);
    const body = (await (await push(accessToken, deviceId, [m])).json()) as any;
    // The L4 guard must NOT fire on an absent parent. The downstream NOT NULL FK may
    // still reject it (VALIDATION_FAILED) — that is the accepted out-of-order path —
    // but it is never the cross-tenant FORBIDDEN rejection.
    expect(body.results[0].reason).not.toBe("FORBIDDEN");
  });
});
