import { env } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { PURGE_ORDER, PROFILE_SCOPED_PURGE_TABLES } from "../src/routes/account";

// Schema guard for DELETE /account. The purge is driven by two hand-maintained lists in
// account.ts: PURGE_ORDER (tables with a user_id column, deleted via WHERE user_id = ?) and
// PROFILE_SCOPED_PURGE_TABLES (keyed by profile_id, no user_id). A new user-scoped table
// missing from BOTH makes account deletion fail with an FK violation (500) — and orphan PII
// — the instant a user actually has rows in it. The empty-path purge tests never catch that
// (it already shipped twice: R2 prefixes, then the whole invoice subsystem). This test reads
// the live schema and fails CI the moment a user-scoped table isn't covered.
//
// Intentionally out of scope: email_tokens is keyed by email (no user_id/profile_id), holds
// only short-lived magic-link codes, and FKs to nothing — it is not per-user purgeable here.

describe("account purge coverage (schema guard)", () => {
  it("every user_id / profile_id scoped table is in a purge list", async () => {
    const { results: tables } = await env.DB
      .prepare(
        "SELECT name FROM sqlite_master WHERE type='table' " +
          "AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '_cf_%' AND name NOT LIKE 'd1_%'",
      )
      .all<{ name: string }>();

    const userIdCovered = new Set<string>(PURGE_ORDER);
    const profileCovered = new Set<string>(PROFILE_SCOPED_PURGE_TABLES);
    const uncovered: string[] = [];

    for (const { name } of tables) {
      const { results: cols } = await env.DB.prepare(`PRAGMA table_info(${name})`).all<{ name: string }>();
      const colNames = new Set(cols.map((c) => c.name));
      if (colNames.has("user_id")) {
        if (!userIdCovered.has(name)) uncovered.push(`${name} (has user_id) → add to PURGE_ORDER`);
      } else if (colNames.has("profile_id")) {
        if (!profileCovered.has(name)) {
          uncovered.push(`${name} (has profile_id, no user_id) → add to PROFILE_SCOPED_PURGE_TABLES`);
        }
      }
    }

    expect(uncovered, `Account deletion would 500 / orphan PII for: ${uncovered.join("; ")}`).toEqual([]);
  });

  it("does not list a table that no longer exists in the schema (lists stay current)", async () => {
    const { results: tables } = await env.DB
      .prepare("SELECT name FROM sqlite_master WHERE type='table'")
      .all<{ name: string }>();
    const live = new Set(tables.map((t) => t.name));
    const stale = [...PURGE_ORDER, ...PROFILE_SCOPED_PURGE_TABLES].filter((t) => !live.has(t));
    expect(stale, `purge list references missing tables: ${stale.join(", ")}`).toEqual([]);
  });
});
