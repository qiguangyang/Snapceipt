import { env, applyD1Migrations } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import { assignQuoteNumber } from "../src/lib/quoteCounter";

declare module "cloudflare:test" {
  interface ProvidedEnv {
    TEST_MIGRATIONS: Parameters<typeof applyD1Migrations>[1];
  }
}

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

beforeEach(async () => {
  await env.DB.exec("DELETE FROM quote_counters");
  await env.DB.exec("DELETE FROM users");
  await env.DB.batch([
    env.DB.prepare(`INSERT OR IGNORE INTO users(id,created_at,updated_at) VALUES('uA',1,1)`),
    env.DB.prepare(`INSERT OR IGNORE INTO users(id,created_at,updated_at) VALUES('uB',1,1)`),
  ]);
});

describe("assignQuoteNumber", () => {
  it("returns SN-0001 then SN-0002 for sequential assigns of one user", async () => {
    expect(await assignQuoteNumber(env.DB, "uA")).toBe("SN-0001");
    expect(await assignQuoteNumber(env.DB, "uA")).toBe("SN-0002");
    expect(await assignQuoteNumber(env.DB, "uA")).toBe("SN-0003");
  });

  it("keeps per-user sequences independent", async () => {
    expect(await assignQuoteNumber(env.DB, "uA")).toBe("SN-0001");
    expect(await assignQuoteNumber(env.DB, "uB")).toBe("SN-0001");
    expect(await assignQuoteNumber(env.DB, "uA")).toBe("SN-0002");
    expect(await assignQuoteNumber(env.DB, "uB")).toBe("SN-0002");
  });
});
