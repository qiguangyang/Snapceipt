import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { signAccess } from "../src/lib/jwt";
import { uuidv7 } from "../src/lib/ids";
import { SYNCABLE_TYPES } from "../src/schemas/entities";
import { tableForEntityType, PROFILE_ID_REQUIRED } from "../src/lib/syncTables";
import { getProcessedMutation, recordProcessedMutation } from "../src/lib/db";

const USER_ID = "01890000-0000-7000-8000-000000000001";
const OTHER_USER_ID = "01890000-0000-7000-8000-0000000000ff";
const DEVICE_ID = "01890000-0000-7000-8000-0000000000d1";
const PROFILE_ID = "01890000-0000-7000-8000-0000000000a1";
const SESSION_ID = "01890000-0000-7000-8000-0000000000c1";

async function seedUserAndProfile() {
  const now = Date.now();
  await env.DB.prepare(
    `INSERT INTO users (id, email, email_verified, plan, created_at, updated_at)
     VALUES (?, ?, 1, 'free', ?, ?)`,
  )
    .bind(USER_ID, "maya@example.com", now, now)
    .run();
  await env.DB.prepare(
    `INSERT INTO profiles (id, user_id, name, type, accent_1, accent_2, accent_3,
       sort_order, is_default, created_at, updated_at, rev)
     VALUES (?, ?, 'Personal', 'personal', '#000', '#111', '#222', 0, 1, ?, ?, 1)`,
  )
    .bind(PROFILE_ID, USER_ID, now, now)
    .run();
}

async function authHeader() {
  const token = await signAccess(env.JWT_SIGNING_KEY, {
    userId: USER_ID,
    sessionId: SESSION_ID,
    deviceId: DEVICE_ID,
  });
  return { Authorization: `Bearer ${token}`, "Content-Type": "application/json" };
}

function txnMutation(overrides: Record<string, unknown> = {}) {
  const entityId = (overrides.entityId as string) ?? uuidv7();
  return {
    mutationId: uuidv7(),
    entityType: "transaction",
    entityId,
    op: "upsert" as const,
    updatedAt: 1_000,
    payload: {
      // Full syncable envelope (the body schema validates payload as baseEnvelope).
      // The server overwrites updatedAt/rev/lastEditedDeviceId regardless of what
      // the client sends.
      id: entityId,
      userId: USER_ID,
      profileId: PROFILE_ID,
      type: "transaction",
      createdAt: 1_000,
      updatedAt: 1_000,
      deletedAt: null,
      rev: 0,
      lastEditedDeviceId: DEVICE_ID,
      catKey: "meals",
      merchant: "The Grounds",
      amountCents: -4200,
      currency: "AUD",
      txnDate: "2026-05-30",
      mode: "personal",
      source: "manual",
    } as Record<string, unknown>,
    ...overrides,
  };
}

async function push(body: unknown) {
  return SELF.fetch("https://api.snapceipt.app/sync/push", {
    method: "POST",
    headers: await authHeader(),
    body: JSON.stringify(body),
  });
}

describe("POST /sync/push", () => {
  beforeEach(async () => {
    // No isolatedStorage guarantee in this harness; reset the rows we touch.
    await env.DB.exec("DELETE FROM processed_mutations");
    await env.DB.exec("DELETE FROM transactions");
    await env.DB.exec("DELETE FROM profiles");
    await env.DB.exec("DELETE FROM users");
    await seedUserAndProfile();
  });

  it("inserts a new entity: applied, rev 1, server-stamped updatedAt", async () => {
    const before = Date.now();
    const m = txnMutation();
    const res = await push({ deviceId: DEVICE_ID, mutations: [m] });
    expect(res.status).toBe(200);
    const json = (await res.json()) as any;
    // Success bodies are unwrapped — no error envelope.
    expect(json.error).toBeUndefined();
    const r = json.results[0];
    expect(r.mutationId).toBe(m.mutationId);
    expect(r.status).toBe("applied");
    expect(r.entity.rev).toBe(1);
    expect(r.entity.lastEditedDeviceId).toBe(DEVICE_ID);
    // server-stamped, NOT the client's updatedAt:1000
    expect(r.entity.updatedAt).toBeGreaterThanOrEqual(before);
    expect(typeof json.serverTime).toBe("number");

    const row = await env.DB.prepare(
      `SELECT rev, updated_at, last_edited_device_id, merchant FROM transactions WHERE id = ?`,
    )
      .bind(m.entityId)
      .first<any>();
    expect(row.rev).toBe(1);
    expect(row.merchant).toBe("The Grounds");
    expect(row.last_edited_device_id).toBe(DEVICE_ID);
  });

  it("replaying the same mutationId is a duplicate no-op", async () => {
    const m = txnMutation();
    const first = (await (await push({ deviceId: DEVICE_ID, mutations: [m] })).json()) as any;
    expect(first.results[0].status).toBe("applied");

    const second = (await (await push({ deviceId: DEVICE_ID, mutations: [m] })).json()) as any;
    expect(second.results[0].status).toBe("duplicate");
    // rev did NOT advance to 2 — the replay returned the prior result
    expect(second.results[0].entity.rev).toBe(1);

    const row = await env.DB.prepare(`SELECT rev FROM transactions WHERE id = ?`)
      .bind(m.entityId)
      .first<any>();
    expect(row.rev).toBe(1);
  });

  it("stale updatedAt loses LWW: conflict, server row echoed", async () => {
    const entityId = uuidv7();
    // First write wins with a high client updatedAt; the server stamp will be > now.
    const win = txnMutation({ entityId, updatedAt: 9_999_999_999_999 });
    win.payload.id = entityId;
    const a = (await (await push({ deviceId: DEVICE_ID, mutations: [win] })).json()) as any;
    expect(a.results[0].status).toBe("applied");
    const serverUpdatedAt = a.results[0].entity.updatedAt;

    // Second mutation with an OLDER updatedAt than the stored server-stamped value.
    const stale = txnMutation({ entityId, updatedAt: 1 });
    stale.payload.id = entityId;
    stale.payload.merchant = "Should Not Persist";
    const b = (await (await push({ deviceId: DEVICE_ID, mutations: [stale] })).json()) as any;
    expect(b.results[0].status).toBe("conflict");
    expect(b.results[0].entity.updatedAt).toBe(serverUpdatedAt);
    expect(b.results[0].entity.merchant).toBe("The Grounds");

    const row = await env.DB.prepare(`SELECT merchant, rev FROM transactions WHERE id = ?`)
      .bind(entityId)
      .first<any>();
    expect(row.merchant).toBe("The Grounds");
    expect(row.rev).toBe(1);
  });

  it("delete sets the tombstone deletedAt, bumps rev, never hard-deletes", async () => {
    const m = txnMutation();
    await push({ deviceId: DEVICE_ID, mutations: [m] });

    // The delete must win LWW against the server-stamped insert, so the client
    // updatedAt has to be >= the stored (server-stamped) value; use a future ms.
    const delTs = Date.now() + 60_000;
    const del = {
      mutationId: uuidv7(),
      entityType: "transaction",
      entityId: m.entityId,
      op: "delete" as const,
      updatedAt: delTs,
      payload: {
        id: m.entityId,
        userId: USER_ID,
        profileId: PROFILE_ID,
        type: "transaction",
        createdAt: 1_000,
        updatedAt: delTs,
        deletedAt: delTs,
        rev: 1,
        lastEditedDeviceId: DEVICE_ID,
      } as Record<string, unknown>,
    };
    const res = (await (await push({ deviceId: DEVICE_ID, mutations: [del] })).json()) as any;
    expect(res.results[0].status).toBe("applied");
    expect(res.results[0].entity.deletedAt).not.toBeNull();
    expect(res.results[0].entity.rev).toBe(2);

    const row = await env.DB.prepare(`SELECT deleted_at, rev FROM transactions WHERE id = ?`)
      .bind(m.entityId)
      .first<any>();
    expect(row).not.toBeNull(); // row still exists
    expect(row.deleted_at).not.toBeNull();
    expect(row.rev).toBe(2);
  });

  it("rejects a payload whose userId is a foreign user (FORBIDDEN)", async () => {
    const m = txnMutation();
    m.payload.userId = OTHER_USER_ID;
    const res = (await (await push({ deviceId: DEVICE_ID, mutations: [m] })).json()) as any;
    expect(res.results[0].status).toBe("rejected");
    expect(res.results[0].reason).toBe("FORBIDDEN");

    const row = await env.DB.prepare(`SELECT id FROM transactions WHERE id = ?`)
      .bind(m.entityId)
      .first<any>();
    expect(row).toBeNull(); // nothing written
  });

  it("applies a mixed batch independently per mutation", async () => {
    const ok = txnMutation();
    const bad = txnMutation();
    bad.payload.userId = OTHER_USER_ID;
    const okDup = ok; // identical mutationId -> duplicate within the same batch order

    const res = (await (
      await push({ deviceId: DEVICE_ID, mutations: [ok, bad, okDup] })
    ).json()) as any;
    expect(res.results).toHaveLength(3);
    // Results preserve batch order. ok and okDup share a mutationId, so a
    // mutationId-keyed map would collapse them — assert by position instead.
    expect(res.results[0].mutationId).toBe(ok.mutationId);
    expect(res.results[0].status).toBe("applied");
    expect(res.results[1].mutationId).toBe(bad.mutationId);
    expect(res.results[1].status).toBe("rejected");
    expect(res.results[1].reason).toBe("FORBIDDEN");
    // the third entry shares ok's mutationId, so it is a duplicate replay
    expect(res.results[2].mutationId).toBe(ok.mutationId);
    expect(res.results[2].status).toBe("duplicate");
  });

  it("rejects a batch larger than 200 mutations with VALIDATION_FAILED (400)", async () => {
    const mutations = Array.from({ length: 201 }, () => txnMutation());
    const res = await push({ deviceId: DEVICE_ID, mutations });
    expect(res.status).toBe(400);
    const json = (await res.json()) as any;
    expect(json.error.code).toBe("VALIDATION_FAILED");
  });

  it("profile upsert persists the persona (profileType -> type), not the envelope discriminant", async () => {
    const entityId = uuidv7();
    const m = {
      mutationId: uuidv7(),
      entityType: "profile",
      entityId,
      op: "upsert" as const,
      updatedAt: 1_000,
      payload: {
        id: entityId,
        userId: USER_ID,
        type: "profile", // envelope discriminant — must NOT land in profiles.type
        createdAt: 1_000,
        updatedAt: 1_000,
        deletedAt: null,
        rev: 0,
        lastEditedDeviceId: DEVICE_ID,
        name: "Acme Pty Ltd",
        profileType: "business", // the persona — this is what profiles.type must hold
        initials: "AP",
        accent1: "#aaa",
        accent2: "#bbb",
        accent3: "#ccc",
        abn: "12345678901",
        gstRegistered: true,
      } as Record<string, unknown>,
    };
    const res = (await (await push({ deviceId: DEVICE_ID, mutations: [m] })).json()) as any;
    expect(res.results[0].status).toBe("applied");

    const row = await env.DB.prepare(
      `SELECT type, name, initials, accent_1, accent_2, accent_3, abn, gst_registered
         FROM profiles WHERE id = ?`,
    )
      .bind(entityId)
      .first<any>();
    expect(row.type).toBe("business"); // the persona, NOT "profile"
    expect(row.name).toBe("Acme Pty Ltd");
    expect(row.initials).toBe("AP");
    expect(row.accent_1).toBe("#aaa");
    expect(row.accent_2).toBe("#bbb");
    expect(row.accent_3).toBe("#ccc");
    expect(row.abn).toBe("12345678901");
    expect(row.gst_registered).toBe(1); // boolean -> 0/1
  });

  it("rejects an upsert that omits profileId for a NOT NULL profile_id table (no row, no 500)", async () => {
    const m = txnMutation();
    delete m.payload.profileId;
    const res = await push({ deviceId: DEVICE_ID, mutations: [m] });
    expect(res.status).toBe(200); // clean per-mutation reject, NOT an unhandled throw
    const json = (await res.json()) as any;
    expect(json.error).toBeUndefined();
    expect(json.results[0].status).toBe("rejected");
    expect(json.results[0].reason).toBe("VALIDATION_FAILED");

    const row = await env.DB.prepare(`SELECT id FROM transactions WHERE id = ?`)
      .bind(m.entityId)
      .first<any>();
    expect(row).toBeNull(); // nothing written
  });
});

describe("syncable table map", () => {
  it("maps all 14 syncable entity types to a table (full coverage)", () => {
    const expected: Record<string, string> = {
      transaction: "transactions",
      lineItem: "line_items",
      profile: "profiles",
      category: "categories",
      smartRule: "smart_rules",
      budget: "budgets",
      loyaltyCard: "loyalty_cards",
      quote: "quotes",
      quoteLineItem: "quote_line_items",
      mileageTrip: "mileage_trips",
      wfhLog: "wfh_logs",
      taxSettings: "tax_settings",
      vehicle: "vehicles",
      vehicleYear: "vehicle_years",
    };
    expect(SYNCABLE_TYPES).toHaveLength(14);
    for (const type of SYNCABLE_TYPES) {
      const meta = tableForEntityType(type);
      expect(meta, `missing table mapping for ${type}`).not.toBeNull();
      expect(meta!.table).toBe(expected[type]);
    }
    // Unknown types map to null.
    expect(tableForEntityType("notAType")).toBeNull();
  });

  it("requires profile_id for the new vehicle + vehicleYear tables", () => {
    expect(PROFILE_ID_REQUIRED.has("vehicle")).toBe(true);
    expect(PROFILE_ID_REQUIRED.has("vehicleYear")).toBe(true);
  });

  it("maps the new mileageTrip logbook columns", () => {
    const meta = tableForEntityType("mileageTrip")!;
    expect(meta.columns.vehicleId).toBe("vehicle_id");
    expect(meta.columns.odometerStartM).toBe("odometer_start_m");
    expect(meta.columns.odometerEndM).toBe("odometer_end_m");
  });

  it("maps the vehicle + vehicleYear domain columns", () => {
    const v = tableForEntityType("vehicle")!;
    expect(v.hasProfileId).toBe(true);
    expect(v.columns.engineCc).toBe("engine_cc");
    expect(v.columns.logbookStartDate).toBe("logbook_start_date");
    expect(v.columns.businessUsePct).toBe("business_use_pct");

    const vy = tableForEntityType("vehicleYear")!;
    expect(vy.hasProfileId).toBe(true);
    expect(vy.columns.vehicleId).toBe("vehicle_id");
    expect(vy.columns.fyStartYear).toBe("fy_start_year");
    expect(vy.columns.depreciationCents).toBe("depreciation_cents");
    expect(vy.columns.claimCents).toBe("claim_cents");
  });
});

describe("getProcessedMutation tenant scoping", () => {
  beforeEach(async () => {
    await env.DB.exec("DELETE FROM processed_mutations");
  });

  it("does not leak another tenant's mutation result across users", async () => {
    const mutationId = uuidv7();
    const entityId = uuidv7();
    // User A records a processed mutation echoing A's own entity.
    await recordProcessedMutation(env.DB, {
      mutationId,
      userId: USER_ID,
      deviceId: DEVICE_ID,
      entityType: "transaction",
      entityId,
      op: "upsert",
      status: "applied",
      resultJson: JSON.stringify({ mutationId, entity: { id: entityId, userId: USER_ID } }),
      createdAt: Date.now(),
    });

    // User A's own lookup finds it.
    const forA = await getProcessedMutation(env.DB, mutationId, USER_ID);
    expect(forA).not.toBeNull();
    expect(forA!.user_id).toBe(USER_ID);

    // User B replaying the SAME mutationId must NOT receive A's row — treated as new.
    const forB = await getProcessedMutation(env.DB, mutationId, OTHER_USER_ID);
    expect(forB).toBeNull();
  });
});
