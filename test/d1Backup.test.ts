import { env } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { d1BackupLogic, backupKey } from "../src/cron/d1Backup";

describe("backupKey", () => {
  it("partitions by UTC date and uses an epoch-ms filename", () => {
    const ms = Date.UTC(2026, 5, 15, 9, 30, 0); // 2026-06-15T09:30:00Z
    expect(backupKey(ms)).toBe(`d1/snapceipt/2026-06-15/${ms}.sql`);
  });
});

describe("d1BackupLogic", () => {
  it("writes a non-empty SQL dump to the BACKUPS bucket under a dated key", async () => {
    const ms = Date.UTC(2026, 5, 15, 9, 30, 0);
    await d1BackupLogic(env.DB, env.BACKUPS, ms);
    const obj = await env.BACKUPS.get(`d1/snapceipt/2026-06-15/${ms}.sql`);
    expect(obj).not.toBeNull();
    const text = await obj!.text();
    // The dump always contains the schema for our core tables.
    expect(text).toContain("CREATE TABLE");
    expect(text).toContain("users");
  });
});
