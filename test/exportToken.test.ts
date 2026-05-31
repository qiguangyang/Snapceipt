import { describe, expect, it } from "vitest";
import { signDownloadToken, verifyDownloadToken, DOWNLOAD_TTL_SECONDS } from "../src/lib/exportToken";

const KEY = "test-signing-key-0123456789-abcdefghijklmnop";

describe("export download token", () => {
  it("round-trips the r2Key", async () => {
    const token = await signDownloadToken(KEY, "u/abc/exports/x.csv");
    const out = await verifyDownloadToken(KEY, token);
    expect(out.r2Key).toBe("u/abc/exports/x.csv");
  });

  it("uses a 7-day TTL", () => {
    expect(DOWNLOAD_TTL_SECONDS).toBe(7 * 24 * 60 * 60);
  });

  it("rejects a forged token (wrong key) -> throws", async () => {
    const token = await signDownloadToken(KEY, "u/abc/exports/x.csv");
    await expect(verifyDownloadToken("a-different-signing-key-0000000000000000", token)).rejects.toThrow();
  });

  it("rejects an expired token -> throws", async () => {
    // Sign with a negative TTL so it is already expired.
    const token = await signDownloadToken(KEY, "u/abc/exports/x.csv", -10);
    await expect(verifyDownloadToken(KEY, token)).rejects.toThrow();
  });
});
