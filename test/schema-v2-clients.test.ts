import { env } from "cloudflare:test";
import { describe, expect, it } from "vitest";

type Column = { name: string; type: string; notnull: number; dflt_value: string | null };
async function columns(table: string) {
  return (await env.DB.prepare(`PRAGMA table_info(${table})`).all<Column>()).results;
}
async function indexes(table: string) {
  const { results } = await env.DB.prepare(`PRAGMA index_list(${table})`).all<{ name: string }>();
  return Promise.all(results.map(async ({ name }) =>
    (await env.DB.prepare(`PRAGMA index_info(${name})`).all<{ name: string }>()).results.map(c => c.name)));
}
async function seedProfile() {
  await env.DB.prepare("INSERT INTO users (id, created_at, updated_at) VALUES ('v2-user', 1, 1)").run();
  await env.DB.prepare("INSERT INTO profiles (id, user_id, name, type, accent_1, accent_2, accent_3, created_at, updated_at) VALUES ('v2-profile', 'v2-user', 'Biz', 'business', '#0', '#1', '#2', 1, 1)").run();
}

describe("v2ColumnsAndTables", () => {
  it("adds nullable notes, client associations, and line units to existing tables", async () => {
    for (const [table, field] of [["clients", "notes"], ["quotes", "client_id"], ["invoices", "client_id"], ["quote_line_items", "unit_label"], ["invoice_line_items", "unit_label"]]) {
      const col = (await columns(table!)).find(c => c.name === field);
      expect(col).toMatchObject({ type: "TEXT", notnull: 0, dflt_value: null });
    }
  });

  it("creates new tables with required profile IDs and the existing sync envelope", async () => {
    for (const table of ["catalog_items", "client_follow_ups"]) {
      const cols = await columns(table);
      for (const field of ["id", "user_id", "profile_id", "created_at", "updated_at", "deleted_at", "rev", "last_edited_device_id"]) {
        expect(cols.find(c => c.name === field), `${table}.${field}`).toBeDefined();
      }
      expect(cols.find(c => c.name === "profile_id")).toMatchObject({ notnull: 1 });
      expect(cols.find(c => c.name === "rev")).toMatchObject({ notnull: 1, dflt_value: "0" });
      for (const field of ["deleted_at", "last_edited_device_id"]) expect(cols.find(c => c.name === field)?.notnull).toBe(0);
      const fks = (await env.DB.prepare(`PRAGMA foreign_key_list(${table})`).all<{ from: string; table: string; to: string }>()).results;
      expect(fks).toEqual(expect.arrayContaining([
        expect.objectContaining({ from: "user_id", table: "users", to: "id" }),
        expect.objectContaining({ from: "profile_id", table: "profiles", to: "id" }),
      ]));
      expect(fks.some(fk => fk.from === "client_id")).toBe(false);
      expect(await indexes(table)).toContainEqual(["user_id", "updated_at"]);
    }
    expect(await columns("catalog_items")).toEqual(expect.arrayContaining([
      expect.objectContaining({ name: "description", type: "TEXT", notnull: 1 }),
      expect.objectContaining({ name: "unit_price_cents", type: "INTEGER", notnull: 1 }),
      expect.objectContaining({ name: "unit_label", type: "TEXT", notnull: 0 }),
      expect.objectContaining({ name: "currency", notnull: 1, dflt_value: "'AUD'" }),
    ]));
    expect(await columns("client_follow_ups")).toEqual(expect.arrayContaining([
      ...["client_id", "title", "timezone"].map(name => expect.objectContaining({ name, type: "TEXT", notnull: 1 })),
      expect.objectContaining({ name: "due_at", type: "INTEGER", notnull: 1 }),
      expect.objectContaining({ name: "completed_at", type: "INTEGER", notnull: 0 }),
    ]));
  });

  it("indexes document client history and due follow-ups in the contract order", async () => {
    for (const table of ["quotes", "invoices"]) expect(await indexes(table)).toContainEqual(["user_id", "profile_id", "client_id", "deleted_at", "created_at"]);
    expect(await indexes("client_follow_ups")).toContainEqual(["user_id", "profile_id", "completed_at", "deleted_at", "due_at"]);
  });

  it("accepts v1 rows without new fields and leaves additions null", async () => {
    await seedProfile();
    await env.DB.batch([
      env.DB.prepare("INSERT INTO clients (id,user_id,profile_id,name,created_at,updated_at) VALUES ('v1-client','v2-user','v2-profile','Acme',1,1)"),
      env.DB.prepare("INSERT INTO quotes (id,user_id,profile_id,created_at,updated_at) VALUES ('v1-quote','v2-user','v2-profile',1,1)"),
      env.DB.prepare("INSERT INTO invoices (id,user_id,profile_id,created_at,updated_at) VALUES ('v1-invoice','v2-user','v2-profile',1,1)"),
      env.DB.prepare("INSERT INTO quote_line_items (id,user_id,quote_id,description,unit_price_cents,created_at,updated_at) VALUES ('v1-ql','v2-user','v1-quote','Work',100,1,1)"),
      env.DB.prepare("INSERT INTO invoice_line_items (id,user_id,invoice_id,description,unit_price_cents,created_at,updated_at) VALUES ('v1-il','v2-user','v1-invoice','Work',100,1,1)"),
    ]);
    for (const [table, field] of [["clients", "notes"], ["quotes", "client_id"], ["invoices", "client_id"], ["quote_line_items", "unit_label"], ["invoice_line_items", "unit_label"]]) {
      expect(await env.DB.prepare(`SELECT ${field} AS value FROM ${table}`).first()).toEqual({ value: null });
    }
  });

  it("requires profile IDs and defaults currency and optional fields on new rows", async () => {
    await seedProfile();
    await env.DB.prepare("INSERT INTO catalog_items (id,user_id,profile_id,description,unit_price_cents,created_at,updated_at) VALUES ('v2-item','v2-user','v2-profile','Work',0,1,1)").run();
    expect(await env.DB.prepare("SELECT currency,unit_label,deleted_at,rev,last_edited_device_id FROM catalog_items WHERE id='v2-item'").first()).toEqual({ currency: "AUD", unit_label: null, deleted_at: null, rev: 0, last_edited_device_id: null });
    // Client IDs are logical links: no FK to clients is introduced.
    await env.DB.prepare("INSERT INTO client_follow_ups (id,user_id,profile_id,client_id,title,due_at,timezone,created_at,updated_at) VALUES ('v2-follow','v2-user','v2-profile','logical-client','Call',0,'Australia/Sydney',1,1)").run();
    expect(await env.DB.prepare("SELECT completed_at FROM client_follow_ups WHERE id='v2-follow'").first()).toEqual({ completed_at: null });
    await expect(env.DB.prepare("INSERT INTO catalog_items (id,user_id,description,unit_price_cents,created_at,updated_at) VALUES ('missing-profile','v2-user','Work',0,1,1)").run()).rejects.toThrow(/NOT NULL/);
    await expect(env.DB.prepare("INSERT INTO client_follow_ups (id,user_id,client_id,title,due_at,timezone,created_at,updated_at) VALUES ('missing-profile','v2-user','logical-client','Call',0,'Australia/Sydney',1,1)").run()).rejects.toThrow(/NOT NULL/);
  });
});
