import { describe, it, expect } from "vitest";
import { isProUser } from "../src/lib/plan";

// Minimal D1 stub: returns the queued row for .first().
function dbReturning(row: unknown) {
  return { prepare: () => ({ bind: () => ({ first: async () => row }) }) } as unknown as D1Database;
}

describe("isProUser", () => {
  it("true for an active pro subscription (no expiry)", async () => {
    const db = dbReturning({ plan: "pro", subscription_status: "active", subscription_expires_at: null });
    expect(await isProUser(db, "u1")).toBe(true);
  });
  it("false for a free plan", async () => {
    const db = dbReturning({ plan: "free", subscription_status: null, subscription_expires_at: null });
    expect(await isProUser(db, "u1")).toBe(false);
  });
  it("false for a revoked pro subscription", async () => {
    const db = dbReturning({ plan: "pro", subscription_status: "revoked", subscription_expires_at: null });
    expect(await isProUser(db, "u1")).toBe(false);
  });
  it("false for an expired pro subscription", async () => {
    const db = dbReturning({ plan: "pro", subscription_status: "active", subscription_expires_at: 1 });
    expect(await isProUser(db, "u1")).toBe(false);
  });
  it("false when the user row is missing", async () => {
    const db = dbReturning(null);
    expect(await isProUser(db, "u1")).toBe(false);
  });
});
