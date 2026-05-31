import { env, applyD1Migrations } from "cloudflare:test";
import { beforeAll, describe, expect, it } from "vitest";

// The migrations array is injected as a Miniflare binding by vitest.config.ts.
declare module "cloudflare:test" {
  interface ProvidedEnv {
    TEST_MIGRATIONS: Parameters<typeof applyD1Migrations>[1];
  }
}

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

async function columnsOf(table: string): Promise<Set<string>> {
  const { results } = await env.DB.prepare(`PRAGMA table_info(${table})`).all<{ name: string }>();
  return new Set(results.map((r) => r.name));
}

describe("devices quiet-hours + timezone columns", () => {
  it("adds quiet_hours_start_min, quiet_hours_end_min, timezone to devices", async () => {
    const cols = await columnsOf("devices");
    for (const c of ["quiet_hours_start_min", "quiet_hours_end_min", "timezone"]) {
      expect(cols.has(c), `devices missing column ${c}`).toBe(true);
    }
  });

  it("makes the three new columns nullable (a device row inserts without them)", async () => {
    await env.DB.batch([
      env.DB.prepare(`INSERT OR IGNORE INTO users(id,created_at,updated_at) VALUES('uqh',1,1)`),
      env.DB.prepare(
        `INSERT INTO devices(id,user_id,platform,push_enabled,created_at,updated_at)
         VALUES('dqh','uqh','ios',1,1,1)`,
      ),
    ]);
    const row = await env.DB.prepare(
      `SELECT quiet_hours_start_min, quiet_hours_end_min, timezone FROM devices WHERE id='dqh'`,
    ).first<{
      quiet_hours_start_min: number | null;
      quiet_hours_end_min: number | null;
      timezone: string | null;
    }>();
    expect(row?.quiet_hours_start_min).toBeNull();
    expect(row?.quiet_hours_end_min).toBeNull();
    expect(row?.timezone).toBeNull();

    // And they round-trip values.
    await env.DB.prepare(
      `UPDATE devices SET quiet_hours_start_min=?, quiet_hours_end_min=?, timezone=? WHERE id='dqh'`,
    )
      .bind(1320, 420, "Australia/Sydney")
      .run();
    const updated = await env.DB.prepare(
      `SELECT quiet_hours_start_min, quiet_hours_end_min, timezone FROM devices WHERE id='dqh'`,
    ).first<{
      quiet_hours_start_min: number;
      quiet_hours_end_min: number;
      timezone: string;
    }>();
    expect(updated?.quiet_hours_start_min).toBe(1320);
    expect(updated?.quiet_hours_end_min).toBe(420);
    expect(updated?.timezone).toBe("Australia/Sydney");
  });
});
