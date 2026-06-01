import { env, applyD1Migrations } from "cloudflare:test";
import { beforeAll, describe, expect, it } from "vitest";

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

async function tableExists(table: string): Promise<boolean> {
  const row = await env.DB
    .prepare(`SELECT name FROM sqlite_master WHERE type='table' AND name=?`)
    .bind(table)
    .first<{ name: string }>();
  return row?.name === table;
}

describe("0002 clients + quote_counters", () => {
  it("creates the clients table with name/email + the sync envelope columns", async () => {
    expect(await tableExists("clients")).toBe(true);
    const cols = await columnsOf("clients");
    for (const c of ["name", "email", "profile_id"]) {
      expect(cols.has(c), `clients missing column ${c}`).toBe(true);
    }
    for (const c of ["id", "user_id", "created_at", "updated_at", "deleted_at", "rev", "last_edited_device_id"]) {
      expect(cols.has(c), `clients missing sync column ${c}`).toBe(true);
    }
  });

  it("creates the quote_counters table with user_id PK + next_seq", async () => {
    expect(await tableExists("quote_counters")).toBe(true);
    const cols = await columnsOf("quote_counters");
    expect(cols.has("user_id")).toBe(true);
    expect(cols.has("next_seq")).toBe(true);
  });

  it("clients round-trips a row (insert + read back)", async () => {
    await env.DB.batch([
      env.DB.prepare(`INSERT OR IGNORE INTO users(id,created_at,updated_at) VALUES('ucl',1,1)`),
      env.DB.prepare(
        `INSERT INTO clients(id,user_id,profile_id,name,email,created_at,updated_at,rev)
         VALUES('cl1','ucl','pcl','Jane Roe','jane@example.com',1,1,0)`,
      ),
    ]);
    const row = await env.DB.prepare(
      `SELECT name, email, profile_id, deleted_at FROM clients WHERE id='cl1'`,
    ).first<{ name: string; email: string | null; profile_id: string | null; deleted_at: number | null }>();
    expect(row?.name).toBe("Jane Roe");
    expect(row?.email).toBe("jane@example.com");
    expect(row?.profile_id).toBe("pcl");
    expect(row?.deleted_at).toBeNull();
  });

  it("quote_counters atomically upserts next_seq via ON CONFLICT … RETURNING", async () => {
    // quote_counters.user_id REFERENCES users(id) and FK enforcement is ON in the
    // D1 test runtime, so the tenant must exist before the counter row is inserted.
    await env.DB.prepare(`INSERT OR IGNORE INTO users(id,created_at,updated_at) VALUES('uctr',1,1)`).run();
    const first = await env.DB.prepare(
      `INSERT INTO quote_counters(user_id, next_seq) VALUES('uctr', 1)
       ON CONFLICT(user_id) DO UPDATE SET next_seq = next_seq + 1
       RETURNING next_seq`,
    ).first<{ next_seq: number }>();
    expect(first?.next_seq).toBe(1);
    const second = await env.DB.prepare(
      `INSERT INTO quote_counters(user_id, next_seq) VALUES('uctr', 1)
       ON CONFLICT(user_id) DO UPDATE SET next_seq = next_seq + 1
       RETURNING next_seq`,
    ).first<{ next_seq: number }>();
    expect(second?.next_seq).toBe(2);
  });
});
