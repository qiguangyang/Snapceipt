// test/smartScan.test.ts
// TDD for the pure helpers + D1 helpers in src/lib/smartScan.ts.
import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import {
  currentPeriod,
  capForPlan,
  getUsage,
  incrementUsage,
  pruneOldUsage,
  DEFAULT_CAP_FREE,
  DEFAULT_CAP_PRO,
} from "../src/lib/smartScan";

// ---------------------------------------------------------------------------
// Pure helpers
// ---------------------------------------------------------------------------

describe("currentPeriod", () => {
  it("converts a known epoch to YYYY-MM UTC", () => {
    // 2026-06-15T10:30:00Z → "2026-06"
    const ms = Date.UTC(2026, 5, 15, 10, 30, 0); // months are 0-indexed
    expect(currentPeriod(ms)).toBe("2026-06");
  });

  it("handles month boundary: last instant of Jan → 2026-01", () => {
    const ms = Date.UTC(2026, 0, 31, 23, 59, 59, 999);
    expect(currentPeriod(ms)).toBe("2026-01");
  });

  it("handles month boundary: first instant of Feb → 2026-02", () => {
    const ms = Date.UTC(2026, 1, 1, 0, 0, 0, 0);
    expect(currentPeriod(ms)).toBe("2026-02");
  });

  it("pads single-digit months with a leading zero", () => {
    const ms = Date.UTC(2026, 0, 1); // January
    expect(currentPeriod(ms)).toBe("2026-01");
  });
});

describe("capForPlan", () => {
  const noOverride = {};

  it("returns DEFAULT_CAP_PRO (500) for plan='pro'", () => {
    expect(capForPlan("pro", noOverride)).toBe(DEFAULT_CAP_PRO);
    expect(capForPlan("pro", noOverride)).toBe(500);
  });

  it("returns DEFAULT_CAP_FREE (10) for plan='free'", () => {
    expect(capForPlan("free", noOverride)).toBe(DEFAULT_CAP_FREE);
    expect(capForPlan("free", noOverride)).toBe(10);
  });

  it("returns DEFAULT_CAP_FREE for plan=null", () => {
    expect(capForPlan(null, noOverride)).toBe(DEFAULT_CAP_FREE);
  });

  it("returns DEFAULT_CAP_FREE for plan=undefined", () => {
    expect(capForPlan(undefined, noOverride)).toBe(DEFAULT_CAP_FREE);
  });

  it("returns DEFAULT_CAP_FREE for an unknown plan string (e.g. 'enterprise')", () => {
    expect(capForPlan("enterprise", noOverride)).toBe(DEFAULT_CAP_FREE);
  });

  it("respects SMART_SCAN_CAP_PRO env override for pro", () => {
    expect(capForPlan("pro", { SMART_SCAN_CAP_PRO: "200" })).toBe(200);
  });

  it("respects SMART_SCAN_CAP_FREE env override for free", () => {
    expect(capForPlan("free", { SMART_SCAN_CAP_FREE: "5" })).toBe(5);
  });

  it("ignores non-numeric SMART_SCAN_CAP_FREE override → falls back to default", () => {
    expect(capForPlan("free", { SMART_SCAN_CAP_FREE: "banana" })).toBe(DEFAULT_CAP_FREE);
  });

  it("ignores SMART_SCAN_CAP_FREE for a pro user", () => {
    // The pro override applies to pro only; free override is irrelevant for pro
    expect(capForPlan("pro", { SMART_SCAN_CAP_FREE: "1" })).toBe(DEFAULT_CAP_PRO);
  });
});

// ---------------------------------------------------------------------------
// D1 helpers (use the test D1 bound in cloudflare:test env)
// ---------------------------------------------------------------------------

beforeEach(async () => {
  await env.DB.exec("DELETE FROM smart_scan_usage");
});

describe("getUsage + incrementUsage", () => {
  it("returns 0 when no row exists", async () => {
    expect(await getUsage(env.DB, "user-a", "2026-06")).toBe(0);
  });

  it("absent → 1 after first increment", async () => {
    await incrementUsage(env.DB, "user-a", "2026-06", Date.UTC(2026, 5, 15));
    expect(await getUsage(env.DB, "user-a", "2026-06")).toBe(1);
  });

  it("1 → 2 after second increment", async () => {
    const t = Date.UTC(2026, 5, 15);
    await incrementUsage(env.DB, "user-a", "2026-06", t);
    await incrementUsage(env.DB, "user-a", "2026-06", t);
    expect(await getUsage(env.DB, "user-a", "2026-06")).toBe(2);
  });

  it("distinct periods are independent", async () => {
    const t = Date.UTC(2026, 5, 15);
    await incrementUsage(env.DB, "user-a", "2026-05", t);
    await incrementUsage(env.DB, "user-a", "2026-05", t);
    await incrementUsage(env.DB, "user-a", "2026-06", t);
    expect(await getUsage(env.DB, "user-a", "2026-05")).toBe(2);
    expect(await getUsage(env.DB, "user-a", "2026-06")).toBe(1);
  });

  it("distinct users are independent", async () => {
    const t = Date.UTC(2026, 5, 15);
    await incrementUsage(env.DB, "user-a", "2026-06", t);
    await incrementUsage(env.DB, "user-a", "2026-06", t);
    await incrementUsage(env.DB, "user-b", "2026-06", t);
    expect(await getUsage(env.DB, "user-a", "2026-06")).toBe(2);
    expect(await getUsage(env.DB, "user-b", "2026-06")).toBe(1);
  });
});

describe("pruneOldUsage", () => {
  it("deletes rows with period < cutoff and keeps current period", async () => {
    const t = Date.UTC(2026, 5, 15);
    // Seed two old periods and one current
    await env.DB.prepare("INSERT INTO smart_scan_usage (user_id, period, count, updated_at) VALUES (?, ?, ?, ?)").bind("user-a", "2026-03", 3, t).run();
    await env.DB.prepare("INSERT INTO smart_scan_usage (user_id, period, count, updated_at) VALUES (?, ?, ?, ?)").bind("user-a", "2026-04", 7, t).run();
    await env.DB.prepare("INSERT INTO smart_scan_usage (user_id, period, count, updated_at) VALUES (?, ?, ?, ?)").bind("user-a", "2026-06", 5, t).run();

    // cutoff = "2026-05" → delete anything < "2026-05" (i.e. 2026-03, 2026-04)
    await pruneOldUsage(env.DB, "2026-05");

    expect(await getUsage(env.DB, "user-a", "2026-03")).toBe(0);
    expect(await getUsage(env.DB, "user-a", "2026-04")).toBe(0);
    expect(await getUsage(env.DB, "user-a", "2026-06")).toBe(5); // kept
  });

  it("keeps cutoff period itself (strict <)", async () => {
    const t = Date.UTC(2026, 5, 15);
    await env.DB.prepare("INSERT INTO smart_scan_usage (user_id, period, count, updated_at) VALUES (?, ?, ?, ?)").bind("user-a", "2026-05", 2, t).run();

    await pruneOldUsage(env.DB, "2026-05");

    // "2026-05" is NOT < "2026-05" → kept
    expect(await getUsage(env.DB, "user-a", "2026-05")).toBe(2);
  });
});
