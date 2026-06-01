import { env } from "cloudflare:test";
import { describe, expect, it } from "vitest";

describe("migration 0003 — email-in server-only tables", () => {
  it("creates profile_inbox_tokens with the expected columns", async () => {
    const info = await env.DB.prepare("PRAGMA table_info(profile_inbox_tokens)").all<{ name: string }>();
    const cols = info.results.map((r) => r.name).sort();
    expect(cols).toEqual(["created_at", "profile_id", "token", "user_id"]);
  });

  it("enforces one row per profile (unique profile_id)", async () => {
    const idx = await env.DB.prepare("PRAGMA index_list(profile_inbox_tokens)").all<{ name: string; unique: number }>();
    const hasUnique = idx.results.some((r) => r.unique === 1);
    expect(hasUnique).toBe(true);
  });

  it("creates inbound_email_log with message_id as the dedup key", async () => {
    const info = await env.DB.prepare("PRAGMA table_info(inbound_email_log)").all<{ name: string; pk: number }>();
    const pk = info.results.filter((r) => r.pk > 0).map((r) => r.name);
    expect(pk).toEqual(["message_id"]);
  });
});
