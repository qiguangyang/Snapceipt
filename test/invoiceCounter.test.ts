import { env, applyD1Migrations } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import { assignInvoiceNumber, formatInvoiceNumber } from "../src/lib/invoiceCounter";

declare module "cloudflare:test" {
  interface ProvidedEnv {
    TEST_MIGRATIONS: Parameters<typeof applyD1Migrations>[1];
  }
}

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

beforeEach(async () => {
  await env.DB.exec("DELETE FROM invoice_counters");
  await env.DB.exec("DELETE FROM profiles");
  await env.DB.exec("DELETE FROM users");
  await env.DB.batch([
    env.DB.prepare(`INSERT OR IGNORE INTO users(id,created_at,updated_at) VALUES('u1',1,1)`),
    env.DB.prepare(
      `INSERT INTO profiles (id,user_id,name,type,accent_1,accent_2,accent_3,created_at,updated_at)
       VALUES ('pA','u1','A','business','#1','#2','#3',1,1)`,
    ),
    env.DB.prepare(
      `INSERT INTO profiles (id,user_id,name,type,accent_1,accent_2,accent_3,created_at,updated_at)
       VALUES ('pB','u1','B','business','#1','#2','#3',1,1)`,
    ),
  ]);
});

describe("formatInvoiceNumber", () => {
  it("zero-pads to 4 digits with the INV- prefix", () => {
    expect(formatInvoiceNumber(1)).toBe("INV-0001");
    expect(formatInvoiceNumber(42)).toBe("INV-0042");
    expect(formatInvoiceNumber(12345)).toBe("INV-12345");
  });
});

describe("assignInvoiceNumber", () => {
  it("returns INV-0001 then INV-0002 for sequential assigns of one profile", async () => {
    expect(await assignInvoiceNumber(env.DB, "pA")).toBe("INV-0001");
    expect(await assignInvoiceNumber(env.DB, "pA")).toBe("INV-0002");
    expect(await assignInvoiceNumber(env.DB, "pA")).toBe("INV-0003");
  });

  it("keeps per-profile sequences independent", async () => {
    expect(await assignInvoiceNumber(env.DB, "pA")).toBe("INV-0001");
    expect(await assignInvoiceNumber(env.DB, "pB")).toBe("INV-0001");
    expect(await assignInvoiceNumber(env.DB, "pA")).toBe("INV-0002");
    expect(await assignInvoiceNumber(env.DB, "pB")).toBe("INV-0002");
  });
});
