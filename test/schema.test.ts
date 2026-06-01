import { env, applyD1Migrations } from "cloudflare:test";
import { beforeAll, describe, expect, it } from "vitest";
import { scopedAll, scopedGet, recordProcessedMutation, getProcessedMutation } from "../src/lib/db";

// The migrations array is injected as a Miniflare binding by vitest.config.ts.
declare module "cloudflare:test" {
  interface ProvidedEnv {
    TEST_MIGRATIONS: Parameters<typeof applyD1Migrations>[1];
  }
}

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

// Every syncable domain table must carry the sync-support columns.
const SYNCABLE = [
  "users", "devices", "profiles", "categories", "smart_rules",
  "transactions", "line_items", "receipt_images", "budgets", "loyalty_cards",
  "mileage_trips", "wfh_logs", "quotes", "quote_line_items", "tax_settings",
  "vehicles", "vehicle_years",
];

// Server-only operational tables (NOT synced to device).
const OPERATIONAL = ["auth_identities", "email_tokens", "sessions", "email_outbox", "processed_mutations"];

async function columnsOf(table: string): Promise<Set<string>> {
  const { results } = await env.DB.prepare(`PRAGMA table_info(${table})`).all<{ name: string }>();
  return new Set(results.map((r) => r.name));
}

async function indexNames(): Promise<Set<string>> {
  const { results } = await env.DB
    .prepare(`SELECT name FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%'`)
    .all<{ name: string }>();
  return new Set(results.map((r) => r.name));
}

describe("0001_init schema", () => {
  it("creates every table", async () => {
    const { results } = await env.DB
      .prepare(`SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '_cf_%' AND name <> 'd1_migrations'`)
      .all<{ name: string }>();
    const names = new Set(results.map((r) => r.name));
    for (const t of [...SYNCABLE, ...OPERATIONAL]) expect(names.has(t), `missing table ${t}`).toBe(true);
  });

  it("removes the Task 1 placeholder _meta table", async () => {
    const { results } = await env.DB
      .prepare(`SELECT name FROM sqlite_master WHERE type='table' AND name='_meta'`)
      .all<{ name: string }>();
    expect(results).toHaveLength(0);
  });

  it("adds sync columns to every syncable table", async () => {
    for (const t of SYNCABLE) {
      const cols = await columnsOf(t);
      for (const c of ["id", "user_id", "created_at", "updated_at", "deleted_at", "rev", "last_edited_device_id"]) {
        expect(cols.has(c), `${t} missing sync column ${c}`).toBe(true);
      }
    }
  });

  it("pins the sessions table shape (family column + refresh-hash unique index)", async () => {
    const cols = await columnsOf("sessions");
    for (const c of [
      "id", "user_id", "device_id", "family", "refresh_hash",
      "created_at", "last_seen_at", "expires_at", "revoked_at",
    ]) {
      expect(cols.has(c), `sessions missing column ${c}`).toBe(true);
    }
    expect(cols.has("family_id"), "sessions must use `family`, not `family_id`").toBe(false);
    const ix = await indexNames();
    expect(ix.has("ix_sessions_family")).toBe(true);
    expect(ix.has("ux_sessions_refresh")).toBe(true);
  });

  it("pins the processed_mutations table shape", async () => {
    const cols = await columnsOf("processed_mutations");
    for (const c of ["mutation_id", "user_id", "result_json", "created_at"]) {
      expect(cols.has(c), `processed_mutations missing column ${c}`).toBe(true);
    }
    const ix = await indexNames();
    expect(ix.has("ix_procmut_user")).toBe(true);
  });

  it("declares the delta-sync backbone + partial read + unique indexes", async () => {
    const ix = await indexNames();
    for (const name of [
      "ix_txn_user_updated", "ix_profiles_user_updated", "ix_budget_user_updated",
      "ix_txn_profile_date", "ix_budget_profile", "ix_quote_profile_status",
      "ux_users_email", "ux_devices_apns", "ux_wfh_profile_date",
      "ux_budget_scope", "ux_quote_number", "ux_img_r2key",
    ]) {
      expect(ix.has(name), `missing index ${name}`).toBe(true);
    }
  });

  it("computes the month_key generated column and round-trips with tenant scoping", async () => {
    await env.DB.batch([
      env.DB.prepare(`INSERT INTO users(id,created_at,updated_at) VALUES('u1',1,1)`),
      env.DB.prepare(`INSERT INTO users(id,created_at,updated_at) VALUES('u2',1,1)`),
      env.DB.prepare(`INSERT INTO profiles(id,user_id,name,type,accent_1,accent_2,accent_3,created_at,updated_at)
                      VALUES('p1','u1','Personal','personal','#0E7C72','#DCF0ED','#0A5950',1,1)`),
      env.DB.prepare(`INSERT INTO transactions(id,user_id,profile_id,cat_key,amount_cents,txn_date,created_at,updated_at)
                      VALUES('t1','u1','p1','meals',-1250,'2026-05-30',10,10)`),
    ]);

    const rows = await scopedAll<{ id: string; amount_cents: number; month_key: string }>(
      env.DB, "transactions", "u1",
    );
    expect(rows).toHaveLength(1);
    const row = rows[0]!;
    expect(row.amount_cents).toBe(-1250);     // money is signed INTEGER cents
    expect(row.month_key).toBe("2026-05");    // STORED generated column

    // Tenant isolation: u2 sees nothing of u1's data.
    const u2rows = await scopedAll(env.DB, "transactions", "u2");
    expect(u2rows).toHaveLength(0);

    const one = await scopedGet<{ id: string }>(env.DB, "transactions", "u1", "t1");
    expect(one?.id).toBe("t1");
    const crossTenant = await scopedGet(env.DB, "transactions", "u2", "t1");
    expect(crossTenant).toBeNull();
  });

  it("records and replays processed mutations idempotently", async () => {
    expect(await getProcessedMutation(env.DB, "mut-1", "u1")).toBeNull();
    await recordProcessedMutation(env.DB, {
      mutationId: "mut-1", userId: "u1", deviceId: "d1",
      entityType: "transaction", entityId: "t1", op: "upsert",
      status: "applied", resultJson: JSON.stringify({ id: "t1" }), createdAt: 100,
    });
    const got = await getProcessedMutation(env.DB, "mut-1", "u1");
    expect(got?.status).toBe("applied");
    expect(got?.entity_id).toBe("t1");
    // Tenant-scoped: u2 replaying the same mutationId does not see u1's row.
    expect(await getProcessedMutation(env.DB, "mut-1", "u2")).toBeNull();
  });

  it("adds the logbook-method columns to mileage_trips", async () => {
    const cols = await columnsOf("mileage_trips");
    for (const c of ["vehicle_id", "odometer_start_m", "odometer_end_m"]) {
      expect(cols.has(c), `mileage_trips missing column ${c}`).toBe(true);
    }
  });

  it("creates the vehicles table with its sync + domain columns", async () => {
    const cols = await columnsOf("vehicles");
    for (const c of [
      "id", "user_id", "profile_id", "make", "model", "engine_cc",
      "registration", "logbook_start_date", "logbook_end_date", "business_use_pct",
      "created_at", "updated_at", "deleted_at", "rev", "last_edited_device_id",
    ]) {
      expect(cols.has(c), `vehicles missing column ${c}`).toBe(true);
    }
    const ix = await indexNames();
    expect(ix.has("ix_vehicle_user_updated")).toBe(true);
    expect(ix.has("ix_vehicle_profile")).toBe(true);
  });

  it("creates the vehicle_years table with its sync + domain columns", async () => {
    const cols = await columnsOf("vehicle_years");
    for (const c of [
      "id", "user_id", "profile_id", "vehicle_id", "fy_start_year",
      "odometer_open_m", "odometer_close_m", "fuel_cents", "rego_cents",
      "insurance_cents", "servicing_cents", "other_cents", "depreciation_cents",
      "business_use_pct", "claim_cents",
      "created_at", "updated_at", "deleted_at", "rev", "last_edited_device_id",
    ]) {
      expect(cols.has(c), `vehicle_years missing column ${c}`).toBe(true);
    }
    const ix = await indexNames();
    expect(ix.has("ux_vehicle_year")).toBe(true);
    expect(ix.has("ix_vehicle_year_user_updated")).toBe(true);
  });

  it("defaults tax_settings.wfh_rate_cents_per_hour to 70 (current ATO rate)", async () => {
    const { results } = await env.DB.prepare(`PRAGMA table_info(tax_settings)`).all<{
      name: string;
      dflt_value: string | null;
    }>();
    const wfh = results.find((r) => r.name === "wfh_rate_cents_per_hour");
    expect(wfh, "wfh_rate_cents_per_hour column missing").toBeDefined();
    expect(Number(wfh!.dflt_value)).toBe(70);
  });

  it("adds the nullable accountant_email column to tax_settings", async () => {
    const cols = await columnsOf("tax_settings");
    expect(cols.has("accountant_email"), "tax_settings missing accountant_email").toBe(true);

    // It is nullable: a tax_settings row inserted without it succeeds.
    await env.DB.batch([
      env.DB.prepare(`INSERT OR IGNORE INTO users(id,created_at,updated_at) VALUES('uacct',1,1)`),
      env.DB.prepare(`INSERT INTO profiles(id,user_id,name,type,accent_1,accent_2,accent_3,created_at,updated_at)
                      VALUES('pacct','uacct','Business','business','#0E7C72','#DCF0ED','#0A5950',1,1)`),
      env.DB.prepare(`INSERT INTO tax_settings(id,user_id,profile_id,created_at,updated_at,rev)
                      VALUES('ts1','uacct','pacct',1,1,1)`),
    ]);
    const row = await env.DB.prepare(`SELECT accountant_email FROM tax_settings WHERE id='ts1'`)
      .first<{ accountant_email: string | null }>();
    expect(row?.accountant_email).toBeNull();

    // And it round-trips a value.
    await env.DB.prepare(`UPDATE tax_settings SET accountant_email=? WHERE id='ts1'`)
      .bind("cpa@example.com").run();
    const updated = await env.DB.prepare(`SELECT accountant_email FROM tax_settings WHERE id='ts1'`)
      .first<{ accountant_email: string | null }>();
    expect(updated?.accountant_email).toBe("cpa@example.com");
  });

  it("round-trips a vehicle through the tenant-scoped helpers", async () => {
    await env.DB.batch([
      env.DB.prepare(`INSERT OR IGNORE INTO users(id,created_at,updated_at) VALUES('uv',1,1)`),
      env.DB.prepare(`INSERT INTO profiles(id,user_id,name,type,accent_1,accent_2,accent_3,created_at,updated_at)
                      VALUES('pv','uv','Personal','personal','#0E7C72','#DCF0ED','#0A5950',1,1)`),
      env.DB.prepare(`INSERT INTO vehicles(id,user_id,profile_id,make,model,business_use_pct,created_at,updated_at,rev)
                      VALUES('veh1','uv','pv','Toyota','HiLux',78,5,5,1)`),
      env.DB.prepare(`INSERT INTO vehicle_years(id,user_id,profile_id,vehicle_id,fy_start_year,fuel_cents,claim_cents,created_at,updated_at,rev)
                      VALUES('vy1','uv','pv','veh1',2025,412000,321360,5,5,1)`),
    ]);

    const vehicles = await scopedAll<{ id: string; make: string; business_use_pct: number }>(
      env.DB, "vehicles", "uv",
    );
    expect(vehicles).toHaveLength(1);
    expect(vehicles[0]!.make).toBe("Toyota");
    expect(vehicles[0]!.business_use_pct).toBe(78);

    const vy = await scopedGet<{ id: string; fy_start_year: number; claim_cents: number }>(
      env.DB, "vehicle_years", "uv", "vy1",
    );
    expect(vy?.fy_start_year).toBe(2025);
    expect(vy?.claim_cents).toBe(321360);
  });
});
