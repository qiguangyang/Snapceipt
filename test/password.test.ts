import { describe, expect, it } from "vitest";
import { hashPassword, verifyPassword } from "../src/lib/password";

describe("password hashing (PBKDF2)", () => {
  it("hashes into a self-describing pbkdf2 string and verifies the right password", async () => {
    const hash = await hashPassword("correct horse battery");
    expect(hash.startsWith("pbkdf2$100000$")).toBe(true);
    expect(hash.split("$").length).toBe(4);
    expect(await verifyPassword("correct horse battery", hash)).toBe(true);
  });

  it("rejects the wrong password", async () => {
    const hash = await hashPassword("supersecret1");
    expect(await verifyPassword("supersecret2", hash)).toBe(false);
    expect(await verifyPassword("", hash)).toBe(false);
  });

  it("uses a fresh salt per hash (same password → different strings)", async () => {
    const a = await hashPassword("supersecret1");
    const b = await hashPassword("supersecret1");
    expect(a).not.toBe(b);
    expect(await verifyPassword("supersecret1", a)).toBe(true);
    expect(await verifyPassword("supersecret1", b)).toBe(true);
  });

  it("returns false on a malformed stored string (never throws)", async () => {
    expect(await verifyPassword("x", "not-a-hash")).toBe(false);
    expect(await verifyPassword("x", "pbkdf2$abc$salt$hash")).toBe(false);
    expect(await verifyPassword("x", "")).toBe(false);
  });
});
