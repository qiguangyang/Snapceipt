import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { signAccess } from "../src/lib/jwt";
import { uuidv7 } from "../src/lib/ids";

// --- helpers -------------------------------------------------------------

const USER_A = uuidv7();
const USER_B = uuidv7();
const DEVICE_A = uuidv7();
const SESSION_A = uuidv7();

// Mint a real access token via the worker's own JWT signer so the auth
// middleware accepts it (real signAccess signature: (key, { userId, sessionId, deviceId })).
async function tokenFor(userId: string) {
  return signAccess(env.JWT_SIGNING_KEY, {
    userId,
    sessionId: SESSION_A,
    deviceId: DEVICE_A,
  });
}

// profiles.user_id / transactions.user_id are NOT NULL REFERENCES users(id) and FK
// enforcement is ON in the D1 test runtime, so the tenant must exist first. users
// is itself syncable, but it is NOT in SYNCABLE_TABLES (server-only), so seeding it
// never affects pull counts.
async function seedUser(userId: string) {
  const now = Date.now();
  await env.DB.prepare(
    `INSERT OR IGNORE INTO users (id, email, email_verified, plan, created_at, updated_at)
     VALUES (?, ?, 1, 'free', ?, ?)`,
  )
    .bind(userId, `${userId}@example.com`, now, now)
    .run();
}

// transactions.profile_id is NOT NULL REFERENCES profiles(id), so every seeded txn
// needs a backing profile. Seed it (idempotently) with a known updatedAt so
// count/order assertions can account for it as its own syncable row.
async function seedProfile(id: string, userId: string, updatedAt: number) {
  await env.DB.prepare(
    `INSERT OR IGNORE INTO profiles
       (id, user_id, name, type, accent_1, accent_2, accent_3,
        created_at, updated_at, deleted_at, rev, last_edited_device_id)
     VALUES (?, ?, 'Personal', 'personal', '#0E7C72', '#DCF0ED', '#0A5950',
             ?, ?, NULL, 1, ?)`,
  )
    .bind(id, userId, updatedAt, updatedAt, DEVICE_A)
    .run();
}

// Insert a minimal-but-valid transactions row. transactions has the most
// NOT NULL columns of the syncable tables, so it exercises the SELECT mapping.
async function seedTxn(opts: {
  id: string;
  userId: string;
  profileId: string;
  updatedAt: number;
  deletedAt?: number | null;
  rev?: number;
  merchant?: string;
}) {
  await env.DB.prepare(
    `INSERT INTO transactions
       (id, user_id, profile_id, merchant, cat_key, amount_cents, currency,
        txn_date, mode, source, created_at, updated_at, deleted_at, rev,
        last_edited_device_id)
     VALUES (?, ?, ?, ?, 'meals', -1234, 'AUD', '2026-05-01', 'personal',
             'manual', ?, ?, ?, ?, ?)`,
  )
    .bind(
      opts.id,
      opts.userId,
      opts.profileId,
      opts.merchant ?? "Test Cafe",
      opts.updatedAt,
      opts.updatedAt,
      opts.deletedAt ?? null,
      opts.rev ?? 1,
      DEVICE_A,
    )
    .run();
}

function pull(token: string, query = "") {
  return SELF.fetch(`https://x/sync/pull${query}`, {
    headers: { authorization: `Bearer ${token}` },
  });
}

// --- tests ---------------------------------------------------------------

describe("GET /sync/pull", () => {
  beforeEach(async () => {
    // transactions references profiles(id) which references users(id) -> delete
    // children first, then (re)seed the two tenants.
    await env.DB.exec("DELETE FROM transactions");
    await env.DB.exec("DELETE FROM profiles");
    await seedUser(USER_A);
    await seedUser(USER_B);
  });

  it("first pull (no cursor) returns all rows incl. a tombstone, globally ordered", async () => {
    const token = await tokenFor(USER_A);
    const profileId = uuidv7();
    await seedProfile(profileId, USER_A, 1000); // profile table (updatedAt 1000)
    await seedTxn({ id: uuidv7(), userId: USER_A, profileId, updatedAt: 2000 });
    await seedTxn({
      id: uuidv7(),
      userId: USER_A,
      profileId,
      updatedAt: 3000,
      deletedAt: 3000, // tombstone MUST be returned
    });

    const res = await pull(token);
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;

    expect(body.changes).toHaveLength(3);
    // globally ordered by (updatedAt, id): profile(1000) then txns(2000,3000)
    const updatedAts = body.changes.map((c: any) => c.updatedAt);
    expect(updatedAts).toEqual([1000, 2000, 3000]);
    // tombstone present
    const tomb = body.changes.find((c: any) => c.deletedAt !== null);
    expect(tomb.deletedAt).toBe(3000);
    // mixed types merged
    expect(body.changes.map((c: any) => c.type)).toContain("profile");
    expect(body.changes.map((c: any) => c.type)).toContain("transaction");
    expect(body.hasMore).toBe(false);
    expect(typeof body.nextCursor).toBe("string");
    expect(typeof body.serverTime).toBe("number");
    // success body is unwrapped (no error envelope)
    expect(body.error).toBeUndefined();
  });

  it("cursor advances and excludes already-seen rows", async () => {
    const token = await tokenFor(USER_A);
    const profileId = uuidv7();
    // Profile at 500 so the first two delta rows are the two txns (1000, 2000).
    await seedProfile(profileId, USER_A, 500);
    await seedTxn({ id: uuidv7(), userId: USER_A, profileId, updatedAt: 1000 });
    await seedTxn({ id: uuidv7(), userId: USER_A, profileId, updatedAt: 2000 });

    // limit=1 -> profile(500) first.
    const first = (await (await pull(token, "?limit=1")).json()) as any;
    expect(first.changes).toHaveLength(1);
    expect(first.changes[0].updatedAt).toBe(500);
    expect(first.changes[0].type).toBe("profile");
    expect(first.hasMore).toBe(true);

    const second = (await (
      await pull(token, `?cursor=${encodeURIComponent(first.nextCursor)}&limit=1`)
    ).json()) as any;
    expect(second.changes).toHaveLength(1);
    expect(second.changes[0].updatedAt).toBe(1000); // strictly after cursor
    expect(second.changes[0].type).toBe("transaction");
    expect(second.hasMore).toBe(true);

    const third = (await (
      await pull(token, `?cursor=${encodeURIComponent(second.nextCursor)}&limit=1`)
    ).json()) as any;
    expect(third.changes).toHaveLength(1);
    expect(third.changes[0].updatedAt).toBe(2000);
    expect(third.hasMore).toBe(false);
  });

  it("breaks updatedAt ties by id (composite keyset, no row skipped or repeated)", async () => {
    const token = await tokenFor(USER_A);
    const profileId = uuidv7();
    await seedProfile(profileId, USER_A, 100);
    // three txns with the SAME updatedAt -> tie broken by id
    const ids = [
      "00000000-0000-0000-0000-000000000001",
      "00000000-0000-0000-0000-000000000002",
      "00000000-0000-0000-0000-000000000003",
    ];
    for (const id of ids) {
      await seedTxn({ id, userId: USER_A, profileId, updatedAt: 5000 });
    }

    const seenTxn: string[] = [];
    let cursor = "";
    for (let i = 0; i < 6; i++) {
      const q = cursor ? `?cursor=${encodeURIComponent(cursor)}&limit=2` : "?limit=2";
      const body = (await (await pull(token, q)).json()) as any;
      for (const c of body.changes) {
        if (c.type === "transaction") seenTxn.push(c.id);
      }
      cursor = body.nextCursor;
      if (!body.hasMore) break;
    }
    expect(seenTxn.sort()).toEqual([...ids].sort()); // every tied row exactly once
    expect(new Set(seenTxn).size).toBe(ids.length);
  });

  it("paginates a mixed-table set with a small limit (no drops/dupes across tables)", async () => {
    const token = await tokenFor(USER_A);
    const profileId = uuidv7();
    // Profile at 4000 creates a cross-table tie with a txn at 4000, stressing the
    // global merge ordering (two different tables sharing an updatedAt).
    await seedProfile(profileId, USER_A, 4000);
    await seedTxn({ id: uuidv7(), userId: USER_A, profileId, updatedAt: 1000 });
    await seedTxn({ id: uuidv7(), userId: USER_A, profileId, updatedAt: 2000 });
    await seedTxn({ id: uuidv7(), userId: USER_A, profileId, updatedAt: 3000 });
    await seedTxn({
      id: uuidv7(),
      userId: USER_A,
      profileId,
      updatedAt: 4000,
      deletedAt: 4000,
    });
    await seedTxn({ id: uuidv7(), userId: USER_A, profileId, updatedAt: 5000 });

    const seen: Array<{ id: string; updatedAt: number }> = [];
    let cursor = "";
    for (let i = 0; i < 20; i++) {
      const q = cursor ? `?cursor=${encodeURIComponent(cursor)}&limit=2` : "?limit=2";
      const body = (await (await pull(token, q)).json()) as any;
      for (const c of body.changes) seen.push({ id: c.id, updatedAt: c.updatedAt });
      cursor = body.nextCursor;
      if (!body.hasMore) break;
    }
    // 6 total rows (1 profile + 5 txns), each exactly once.
    expect(seen).toHaveLength(6);
    expect(new Set(seen.map((s) => s.id)).size).toBe(6);
    // Globally non-decreasing by updatedAt across the whole walk.
    const ats = seen.map((s) => s.updatedAt);
    expect(ats).toEqual([1000, 2000, 3000, 4000, 4000, 5000]);
  });

  it("scopes rows to the authed user only", async () => {
    const tokenA = await tokenFor(USER_A);
    const profA = uuidv7();
    const profB = uuidv7();
    await seedProfile(profA, USER_A, 1000);
    await seedProfile(profB, USER_B, 1000);
    await seedTxn({ id: uuidv7(), userId: USER_A, profileId: profA, updatedAt: 2000, merchant: "MineA" });
    await seedTxn({ id: uuidv7(), userId: USER_B, profileId: profB, updatedAt: 2000, merchant: "NotMine" });

    const body = (await (await pull(tokenA)).json()) as any;
    // USER_A sees only their profile + their txn; USER_B's rows never appear.
    expect(body.changes).toHaveLength(2);
    const merchants = body.changes.map((c: any) => c.merchant);
    expect(merchants).toContain("MineA");
    expect(merchants).not.toContain("NotMine");
    for (const c of body.changes) expect(c.userId).toBe(USER_A);
  });

  it("treats a malformed cursor as a full sync (decodeCursor null per contract)", async () => {
    const token = await tokenFor(USER_A);
    const profileId = uuidv7();
    await seedProfile(profileId, USER_A, 1000);
    await seedTxn({ id: uuidv7(), userId: USER_A, profileId, updatedAt: 2000 });
    // A garbage cursor decodes to null -> full sync (no keyset filter), 200 OK.
    const res = await pull(token, "?cursor=not-base64url-{}");
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;
    expect(body.changes).toHaveLength(2); // profile + txn, full snapshot
    expect(body.changes[0].updatedAt).toBe(1000);
  });

  it("returns an empty delta with hasMore=false when nothing is new", async () => {
    const token = await tokenFor(USER_A);
    const body = (await (await pull(token)).json()) as any;
    expect(body.changes).toEqual([]);
    expect(body.hasMore).toBe(false);
    expect(typeof body.nextCursor).toBe("string");
  });
});

describe("GET /sync/pull — logbook entities", () => {
  async function seedVehicle(opts: {
    id: string;
    userId: string;
    profileId: string;
    updatedAt: number;
    deletedAt?: number | null;
    businessUsePct?: number;
  }) {
    await env.DB.prepare(
      `INSERT INTO vehicles
         (id, user_id, profile_id, make, model, engine_cc, registration,
          logbook_start_date, logbook_end_date, business_use_pct,
          created_at, updated_at, deleted_at, rev, last_edited_device_id)
       VALUES (?, ?, ?, 'Toyota', 'HiLux', 2800, 'ABC123',
               '2025-08-12', '2025-11-04', ?, ?, ?, ?, 1, ?)`,
    )
      .bind(
        opts.id, opts.userId, opts.profileId, opts.businessUsePct ?? 78,
        opts.updatedAt, opts.updatedAt, opts.deletedAt ?? null, DEVICE_A,
      )
      .run();
  }

  async function seedVehicleYear(opts: {
    id: string;
    userId: string;
    profileId: string;
    vehicleId: string;
    updatedAt: number;
    deletedAt?: number | null;
  }) {
    await env.DB.prepare(
      `INSERT INTO vehicle_years
         (id, user_id, profile_id, vehicle_id, fy_start_year,
          fuel_cents, rego_cents, insurance_cents, servicing_cents, other_cents,
          depreciation_cents, business_use_pct, claim_cents,
          created_at, updated_at, deleted_at, rev, last_edited_device_id)
       VALUES (?, ?, ?, ?, 2025, 220000, 90000, 60000, 30000, 12000,
               100000, 78, 321360, ?, ?, ?, 1, ?)`,
    )
      .bind(
        opts.id, opts.userId, opts.profileId, opts.vehicleId,
        opts.updatedAt, opts.updatedAt, opts.deletedAt ?? null, DEVICE_A,
      )
      .run();
  }

  async function seedMileageTrip(opts: {
    id: string;
    userId: string;
    profileId: string;
    vehicleId: string;
    updatedAt: number;
  }) {
    await env.DB.prepare(
      `INSERT INTO mileage_trips
         (id, user_id, profile_id, trip_date, purpose, distance_m, is_business,
          auto_tracked, vehicle_id, odometer_start_m, odometer_end_m,
          created_at, updated_at, deleted_at, rev, last_edited_device_id)
       VALUES (?, ?, ?, '2025-09-01', 'Client visit', 23000, 1,
               0, ?, 45000000, 45023000, ?, ?, NULL, 1, ?)`,
    )
      .bind(
        opts.id, opts.userId, opts.profileId, opts.vehicleId,
        opts.updatedAt, opts.updatedAt, DEVICE_A,
      )
      .run();
  }

  beforeEach(async () => {
    await env.DB.exec("DELETE FROM mileage_trips");
    await env.DB.exec("DELETE FROM vehicle_years");
    await env.DB.exec("DELETE FROM vehicles");
    await env.DB.exec("DELETE FROM transactions");
    await env.DB.exec("DELETE FROM profiles");
    await seedUser(USER_A);
  });

  it("pulls a vehicle with camelCase wire fields", async () => {
    const token = await tokenFor(USER_A);
    const profileId = uuidv7();
    const vehicleId = uuidv7();
    await seedProfile(profileId, USER_A, 1000);
    await seedVehicle({ id: vehicleId, userId: USER_A, profileId, updatedAt: 2000 });

    const body = (await (await pull(token)).json()) as any;
    const v = body.changes.find((c: any) => c.type === "vehicle");
    expect(v).toBeDefined();
    expect(v.id).toBe(vehicleId);
    expect(v.profileId).toBe(profileId);
    expect(v.make).toBe("Toyota");
    expect(v.engineCc).toBe(2800);
    expect(v.logbookStartDate).toBe("2025-08-12");
    expect(v.businessUsePct).toBe(78);
    expect(v.userId).toBe(USER_A);
  });

  it("pulls a vehicleYear with camelCase cents + claim fields", async () => {
    const token = await tokenFor(USER_A);
    const profileId = uuidv7();
    const vehicleId = uuidv7();
    const vyId = uuidv7();
    await seedProfile(profileId, USER_A, 1000);
    await seedVehicle({ id: vehicleId, userId: USER_A, profileId, updatedAt: 2000 });
    await seedVehicleYear({ id: vyId, userId: USER_A, profileId, vehicleId, updatedAt: 3000 });

    const body = (await (await pull(token)).json()) as any;
    const vy = body.changes.find((c: any) => c.type === "vehicleYear");
    expect(vy).toBeDefined();
    expect(vy.id).toBe(vyId);
    expect(vy.vehicleId).toBe(vehicleId);
    expect(vy.fyStartYear).toBe(2025);
    expect(vy.fuelCents).toBe(220000);
    expect(vy.depreciationCents).toBe(100000);
    expect(vy.claimCents).toBe(321360);
  });

  it("pulls a mileageTrip with the new odometer/vehicle wire fields", async () => {
    const token = await tokenFor(USER_A);
    const profileId = uuidv7();
    const vehicleId = uuidv7();
    await seedProfile(profileId, USER_A, 1000);
    await seedVehicle({ id: vehicleId, userId: USER_A, profileId, updatedAt: 2000 });
    await seedMileageTrip({ id: uuidv7(), userId: USER_A, profileId, vehicleId, updatedAt: 4000 });

    const body = (await (await pull(token)).json()) as any;
    const trip = body.changes.find((c: any) => c.type === "mileageTrip");
    expect(trip).toBeDefined();
    expect(trip.vehicleId).toBe(vehicleId);
    expect(trip.odometerStartM).toBe(45000000);
    expect(trip.odometerEndM).toBe(45023000);
    expect(trip.distanceM).toBe(23000);
  });

  it("includes a vehicle tombstone and orders the logbook stream globally", async () => {
    const token = await tokenFor(USER_A);
    const profileId = uuidv7();
    const vehicleId = uuidv7();
    const vyId = uuidv7();
    await seedProfile(profileId, USER_A, 1000);
    await seedVehicle({ id: vehicleId, userId: USER_A, profileId, updatedAt: 2000 });
    await seedVehicleYear({
      id: vyId,
      userId: USER_A,
      profileId,
      vehicleId,
      updatedAt: 3000,
      deletedAt: 3000, // tombstone MUST be returned
    });

    const body = (await (await pull(token)).json()) as any;
    expect(body.changes).toHaveLength(3); // profile + vehicle + vehicleYear(tombstone)
    const updatedAts = body.changes.map((c: any) => c.updatedAt);
    expect(updatedAts).toEqual([1000, 2000, 3000]);
    const tomb = body.changes.find((c: any) => c.type === "vehicleYear");
    expect(tomb.deletedAt).toBe(3000);
    expect(body.hasMore).toBe(false);
  });

  it("scopes logbook rows to the authed user only", async () => {
    const tokenA = await tokenFor(USER_A);
    await seedUser(USER_B);
    const profA = uuidv7();
    const profB = uuidv7();
    await seedProfile(profA, USER_A, 1000);
    await seedProfile(profB, USER_B, 1000);
    await seedVehicle({ id: uuidv7(), userId: USER_A, profileId: profA, updatedAt: 2000 });
    await seedVehicle({ id: uuidv7(), userId: USER_B, profileId: profB, updatedAt: 2000 });

    const body = (await (await pull(tokenA)).json()) as any;
    const vehicles = body.changes.filter((c: any) => c.type === "vehicle");
    expect(vehicles).toHaveLength(1);
    for (const c of body.changes) expect(c.userId).toBe(USER_A);
  });
});
