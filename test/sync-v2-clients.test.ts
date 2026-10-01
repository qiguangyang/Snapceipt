import { env, SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { uuidv7 } from "../src/lib/ids";
import { signAccess } from "../src/lib/jwt";
import { seedSession } from "./helpers/session";
import { app } from "../src/app";

async function setup() {
  const userId = uuidv7(), deviceId = uuidv7(), sessionId = uuidv7();
  await env.DB.prepare("INSERT INTO users(id,created_at,updated_at) VALUES(?,1,1)").bind(userId).run();
  const profileId = await profile(userId);
  await seedSession({ id: sessionId, userId, deviceId });
  const token = await signAccess(env.JWT_SIGNING_KEY, { userId, deviceId, sessionId });
  const headers = { Authorization: `Bearer ${token}`, "Content-Type": "application/json" };
  function mutation(entityType: string, fields: Record<string, unknown> = {}, id = uuidv7()) {
    const now = Date.now() + 60_000;
    return {
      mutationId: uuidv7(), entityType, entityId: id, op: "upsert", updatedAt: now,
      payload: { id, userId, profileId, createdAt: now, updatedAt: now, rev: 0, deletedAt: null, ...fields } as Record<string, unknown>,
    };
  }
  function pushRaw(...mutations: ReturnType<typeof mutation>[]) {
    return SELF.fetch("https://api.test/sync/push", {
      method: "POST", headers, body: JSON.stringify({ deviceId, mutations }),
    });
  }
  async function push(...mutations: ReturnType<typeof mutation>[]) {
    const response = await pushRaw(...mutations);
    expect(response.status).toBe(200);
    return ((await response.json()) as any).results as any[];
  }
  async function pull() {
    const response = await SELF.fetch("https://api.test/sync/pull?limit=500", { headers });
    expect(response.status).toBe(200);
    return ((await response.json()) as any).changes as any[];
  }
  return { userId, deviceId, headers, profileId, mutation, push, pushRaw, pull };
}

async function profile(userId: string, type = "business", deletedAt: number | null = null) {
  const id = uuidv7();
  await env.DB.prepare(`INSERT INTO profiles(id,user_id,name,type,accent_1,accent_2,accent_3,created_at,updated_at,deleted_at)
    VALUES(?,?,'Workspace',?,'#1','#2','#3',1,1,?)`).bind(id, userId, type, deletedAt).run();
  return id;
}

function rejected(result: any, reason = "VALIDATION_FAILED") {
  expect(result).toMatchObject({ status: "rejected", reason, entity: null });
}

describe("v2 apply-time sync validation", () => {
  it("noTypeV2RoundTrip: normalizes and pulls v2 fields without a type tag", async () => {
    const s = await setup();
    const client = s.mutation("client", { name: " Acme ", notes: " Call on Mondays " });
    const quote = s.mutation("quote", { clientId: client.entityId, clientName: "Historic name" });
    const invoice = s.mutation("invoice", { clientId: client.entityId });
    const qLine = s.mutation("quoteLineItem", { quoteId: quote.entityId, description: "Labour", unitLabel: " hour ", unitPriceCents: 1000, quantity: 1 });
    const iLine = s.mutation("invoiceLineItem", { invoiceId: invoice.entityId, itemDescription: "Labour", unitLabel: " ", unitPriceCents: 1000, quantity: 1 });
    const item = s.mutation("catalogItem", { itemDescription: " Labour ", unitLabel: " hour ", unitPriceCents: 1000 });
    const reminder = s.mutation("clientFollowUp", { clientId: client.entityId, title: " Call back ", dueAt: Date.now(), timezone: "Australia/Sydney", completedAt: null });
    const results = await s.push(client, quote, invoice, qLine, iLine, item, reminder);
    expect(results.map(r => r.status)).toEqual(Array(7).fill("applied"));
    const changes = await s.pull();
    const get = (id: string) => changes.find(c => c.id === id);
    expect(get(client.entityId)).toMatchObject({ name: "Acme", notes: "Call on Mondays" });
    expect(get(quote.entityId)).toMatchObject({ clientId: client.entityId, clientName: "Historic name" });
    expect(get(invoice.entityId)).toMatchObject({ clientId: client.entityId });
    expect(get(qLine.entityId)).toMatchObject({ unitLabel: "hour" });
    expect(get(iLine.entityId)).toMatchObject({ unitLabel: null });
    expect(get(item.entityId)).toMatchObject({ itemDescription: "Labour", unitLabel: "hour", unitPriceCents: 1000, currency: "AUD" });
    expect(get(reminder.entityId)).toMatchObject({ title: "Call back", dueAt: reminder.payload.dueAt, timezone: "Australia/Sydney", completedAt: null });
  });

  it("foreignOrOtherProfileClientRejected: does not change document snapshots or links", async () => {
    const s = await setup(), other = await setup();
    const foreign = other.mutation("client", { name: "Other tenant" });
    await other.push(foreign);
    const otherProfile = await profile(s.userId);
    const client = s.mutation("client", { name: "Other workspace", profileId: otherProfile });
    await s.push(client);
    for (const type of ["quote", "invoice"]) {
      const doc = s.mutation(type, { clientName: "Snapshot" });
      expect((await s.push(doc))[0].status).toBe("applied");
      for (const clientId of [foreign.entityId, client.entityId]) {
        rejected((await s.push(s.mutation(type, { clientId, clientName: "Changed" }, doc.entityId)))[0], "FORBIDDEN");
      }
      expect((await s.pull()).find(c => c.id === doc.entityId)).toMatchObject({ clientId: null, clientName: "Snapshot" });
    }
    rejected((await s.push(s.mutation("clientFollowUp", { clientId: foreign.entityId, title: "Call", dueAt: 1, timezone: "UTC" })))[0], "FORBIDDEN");
  });

  it("unknownOrDeletedNewLinkRejected: existing document tombstone links remain valid", async () => {
    const s = await setup();
    const client = s.mutation("client", { name: "Acme" });
    const quote = s.mutation("quote", { clientId: client.entityId });
    const invoice = s.mutation("invoice", { clientId: client.entityId });
    await s.push(client, quote, invoice);
    const deletion = s.mutation("client", {}, client.entityId);
    deletion.op = "delete";
    expect((await s.push(deletion))[0].status).toBe("applied");
    for (const type of ["quote", "invoice", "clientFollowUp"]) {
      for (const clientId of [uuidv7(), client.entityId]) {
        rejected((await s.push(s.mutation(type, { clientId, title: "Call", dueAt: 1, timezone: "UTC" })))[0]);
      }
    }
    expect((await s.push(s.mutation("quote", { clientId: client.entityId }, quote.entityId)))[0].status).toBe("applied");
    expect((await s.push(s.mutation("invoice", {}, invoice.entityId)))[0].status).toBe("applied");
  });

  it("oldPayloadPreservesV2Fields: omission retains fields and explicit null clears them", async () => {
    const s = await setup();
    const client = s.mutation("client", { name: "Acme", notes: "Notes" });
    const quote = s.mutation("quote", { clientId: client.entityId, clientName: "Snapshot" });
    const line = s.mutation("quoteLineItem", { quoteId: quote.entityId, description: "Work", quantity: 1, unitPriceCents: 10, unitLabel: "hour" });
    await s.push(client, quote, line);
    const quoteEdit = s.mutation("quote", { clientName: "Snapshot" }, quote.entityId);
    delete (quoteEdit.payload as Record<string, unknown>).profileId;
    const edits = await s.push(s.mutation("client", { name: "Acme" }, client.entityId), quoteEdit,
      s.mutation("quoteLineItem", { quoteId: quote.entityId, description: "Work", unitPriceCents: 10 }, line.entityId));
    expect(edits.map(r => r.status)).toEqual(["applied", "applied", "applied"]);
    const changes = await s.pull();
    expect(changes.find(c => c.id === client.entityId).notes).toBe("Notes");
    expect(changes.find(c => c.id === quote.entityId)).toMatchObject({ clientId: client.entityId, profileId: s.profileId });
    expect(changes.find(c => c.id === line.entityId).unitLabel).toBe("hour");
    const cleared = await s.push(s.mutation("quote", { clientId: null }, quote.entityId),
      s.mutation("client", { name: "Acme", notes: null }, client.entityId),
      s.mutation("quoteLineItem", { quoteId: quote.entityId, description: "Work", unitPriceCents: 10, unitLabel: null }, line.entityId));
    expect(cleared.map(r => r.status)).toEqual(["applied", "applied", "applied"]);
    expect(cleared.map(r => r.entity.clientId ?? r.entity.notes ?? r.entity.unitLabel ?? null)).toEqual([null, null, null]);
  });

  it.each([
    ["client", { name: " " }], ["client", { name: "x".repeat(201) }], ["client", { name: "Acme", notes: "x".repeat(10_001) }],
    ["client", { name: "Acme", notes: 42 }],
    ["quote", { clientId: "bad-id" }], ["invoice", { clientId: "bad-id" }],
    ["quoteLineItem", { unitLabel: 42 }], ["invoiceLineItem", { unitLabel: "x".repeat(41) }],
    ["catalogItem", { itemDescription: " " }], ["catalogItem", { itemDescription: "x".repeat(501) }],
    ["catalogItem", { unitPriceCents: -1 }], ["catalogItem", { unitPriceCents: 1_000_000_001 }],
    ["catalogItem", { unitPriceCents: 1.5 }], ["catalogItem", { unitLabel: false }],
    ["catalogItem", { createdAt: Number.MAX_SAFE_INTEGER + 1 }],
    ["catalogItem", { updatedAt: Number.MAX_SAFE_INTEGER + 1 }],
    ["catalogItem", { id: "01890000-0000-4000-8000-0000000000a1" }],
    ["quote", { clientId: "01890000-0000-4000-8000-0000000000a1" }],
    ["clientFollowUp", { title: " " }], ["clientFollowUp", { title: "x".repeat(201) }],
    ["clientFollowUp", { dueAt: 1.5 }], ["clientFollowUp", { dueAt: -1 }],
    ["clientFollowUp", { completedAt: 1.5 }], ["clientFollowUp", { completedAt: Number.MAX_SAFE_INTEGER + 1 }],
    ["clientFollowUp", { timezone: "not/a/zone" }], ["clientFollowUp", { timezone: "+10:00" }],
    ["clientFollowUp", { clientId: "bad-id" }],
  ])("invalidV2ScalarsRejected: %s %j", async (type, fields) => {
    const s = await setup();
    const client = s.mutation("client", { name: "Acme" });
    const quote = s.mutation("quote");
    const invoice = s.mutation("invoice");
    await s.push(client, quote, invoice);
    const defaults: Record<string, unknown> = { name: "Acme", itemDescription: "Work", description: "Work", quantity: 1, unitPriceCents: 10,
      quoteId: quote.entityId, invoiceId: invoice.entityId, clientId: client.entityId, title: "Call", dueAt: 1, timezone: "UTC" };
    const mutation = s.mutation(type, { ...defaults, ...fields }, "id" in fields ? String(fields.id) : uuidv7());
    rejected((await s.push(mutation))[0]);
    expect((await s.pull()).some(c => c.id === mutation.entityId)).toBe(false);
  });

  it("profileMoveWithLinkedRecordsRejected: moving either side cannot invalidate live links", async () => {
    const s = await setup(), targetProfile = await profile(s.userId);
    const client = s.mutation("client", { name: "Acme" });
    const quote = s.mutation("quote", { clientId: client.entityId });
    const invoice = s.mutation("invoice", { clientId: client.entityId });
    const reminder = s.mutation("clientFollowUp", { clientId: client.entityId, title: "Call", dueAt: 1, timezone: "UTC" });
    await s.push(client, quote, invoice, reminder);
    for (const mutation of [client, quote, invoice, reminder]) {
      rejected((await s.push(s.mutation(mutation.entityType, { ...mutation.payload, profileId: targetProfile }, mutation.entityId)))[0], "FORBIDDEN");
    }
    // Tombstoned links do not prevent moving the remaining client.
    for (const mutation of [quote, invoice, reminder]) {
      const deletion = s.mutation(mutation.entityType, {}, mutation.entityId); deletion.op = "delete";
      expect((await s.push(deletion))[0].status).toBe("applied");
    }
    expect((await s.push(s.mutation("client", { name: "Acme", profileId: targetProfile }, client.entityId)))[0].status).toBe("applied");
  });

  it("newClientThenDocumentInOneBatch: reverse ordering rejects only the dependent mutation", async () => {
    const s = await setup();
    const parent = s.mutation("client", { name: "Acme" });
    const child = s.mutation("quote", { clientId: parent.entityId });
    expect((await s.push(parent, child)).map(r => r.status)).toEqual(["applied", "applied"]);
    const parent2 = s.mutation("client", { name: "Acme 2" });
    const child2 = s.mutation("clientFollowUp", { clientId: parent2.entityId, title: "Call", dueAt: 1, timezone: "UTC" });
    const results = await s.push(child2, parent2);
    rejected(results[0]); expect(results[1].status).toBe("applied");
    expect((await s.push(child2))[0]).toMatchObject({ status: "duplicate", reason: "VALIDATION_FAILED" });
    expect((await s.push(s.mutation("clientFollowUp", child2.payload, child2.entityId)))[0].status).toBe("applied");
  });

  it("new entities require an owned live business profile without tightening old entities", async () => {
    const s = await setup(), other = await setup();
    const personal = await profile(s.userId, "personal"), deleted = await profile(s.userId, "business", 1);
    const client = s.mutation("client", { name: "Acme", profileId: personal });
    expect((await s.push(client))[0].status).toBe("applied");
    for (const type of ["catalogItem", "clientFollowUp"]) {
      for (const profileId of [personal, deleted, other.profileId]) {
        rejected((await s.push(s.mutation(type, { profileId, itemDescription: "Work", unitPriceCents: 10,
          clientId: client.entityId, title: "Call", dueAt: 1, timezone: "UTC" })))[0], "FORBIDDEN");
      }
      const missing = s.mutation(type, { itemDescription: "Work", unitPriceCents: 10, clientId: client.entityId, title: "Call", dueAt: 1, timezone: "UTC" });
      delete (missing.payload as Record<string, unknown>).profileId;
      rejected((await s.push(missing))[0]);
      // The existing wire envelope rejects explicit null profileId before apply.
      expect((await s.pushRaw(s.mutation(type, { ...missing.payload, profileId: null }))).status).toBe(400);
    }
  });

  it("merged v2 edits retain required fields, links, prices and reminder state", async () => {
    const s = await setup();
    const client = s.mutation("client", { name: "Acme", notes: "Original" });
    const item = s.mutation("catalogItem", { itemDescription: "Work", unitPriceCents: 1_000_000_000, unitLabel: "hour", currency: "AUD" });
    const reminder = s.mutation("clientFollowUp", { clientId: client.entityId, title: "Call", dueAt: 0, timezone: "Australia/Sydney", completedAt: 10 });
    await s.push(client, item, reminder);
    const edits = [s.mutation("client", { notes: "Updated" }, client.entityId),
      s.mutation("catalogItem", { unitPriceCents: 0 }, item.entityId),
      s.mutation("clientFollowUp", { completedAt: null }, reminder.entityId)];
    for (const edit of edits) delete edit.payload.profileId;
    const results = await s.push(...edits);
    expect(results.map(r => r.status)).toEqual(["applied", "applied", "applied"]);
    expect(results[0].entity).toMatchObject({ name: "Acme", notes: "Updated", profileId: s.profileId });
    expect(results[1].entity).toMatchObject({ itemDescription: "Work", unitLabel: "hour", unitPriceCents: 0 });
    expect(results[2].entity).toMatchObject({ clientId: client.entityId, title: "Call", dueAt: 0, timezone: "Australia/Sydney", completedAt: null });
  });

  it("invalid edits preserve the old row while valid siblings still apply", async () => {
    const s = await setup();
    const item = s.mutation("catalogItem", { itemDescription: "Original", unitPriceCents: 100 });
    await s.push(item);
    const invalid = s.mutation("catalogItem", { itemDescription: "Changed", unitPriceCents: -1 }, item.entityId);
    const valid = s.mutation("client", { name: "Acme" });
    const results = await s.push(invalid, valid);
    rejected(results[0]); expect(results[1].status).toBe("applied");
    expect((await s.pull()).find(c => c.id === item.entityId)).toMatchObject({ itemDescription: "Original", unitPriceCents: 100 });
  });

  it("new entity mutation timestamps must be safe integers", async () => {
    const s = await setup();
    const item = s.mutation("catalogItem", { itemDescription: "Work", unitPriceCents: 100 });
    item.updatedAt = Number.MAX_SAFE_INTEGER + 1;
    rejected((await s.push(item))[0]);
  });

  it("omitted server fields survive a server update during reference validation", async () => {
    const s = await setup();
    const client = s.mutation("client", { name: "Acme" });
    const quote = s.mutation("quote", { clientId: client.entityId, pdfR2Key: "old.pdf", status: "draft" });
    await s.push(client, quote);
    let interleaved = false;
    const db = {
      prepare(sql: string) {
        if (sql.startsWith("SELECT deleted_at FROM clients")) {
          return { bind(...values: unknown[]) {
            return { async first() {
              const result = await env.DB.prepare(sql).bind(...values).first();
              await env.DB.prepare("UPDATE quotes SET pdf_r2_key = 'new.pdf', status = 'sent' WHERE id = ? AND user_id = ? AND profile_id = ?")
                .bind(quote.entityId, s.userId, s.profileId).run();
              interleaved = true;
              return result;
            } };
          } } as D1PreparedStatement;
        }
        return env.DB.prepare(sql);
      },
      batch: env.DB.batch.bind(env.DB),
    } as D1Database;
    const edit = s.mutation("quote", { clientName: "Historic snapshot" }, quote.entityId);
    delete edit.payload.profileId;
    const response = await app.request("/sync/push", {
      method: "POST", headers: s.headers, body: JSON.stringify({ deviceId: s.deviceId, mutations: [edit] }),
    }, { ...env, DB: db });
    expect(response.status).toBe(200);
    expect(((await response.json()) as any).results[0].status).toBe("applied");
    expect(interleaved).toBe(true);
    expect((await s.pull()).find(c => c.id === quote.entityId)).toMatchObject({ pdfR2Key: "new.pdf", status: "sent", clientName: "Historic snapshot" });
  });
});
