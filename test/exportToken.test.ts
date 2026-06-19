import { describe, expect, it } from "vitest";
import { signDownloadToken, verifyDownloadToken, DOWNLOAD_TTL_SECONDS } from "../src/lib/exportToken";
import { signQuoteLinkToken, verifyQuoteLinkToken, QUOTE_LINK_TTL_SECONDS } from "../src/lib/exportToken";
import { signAccess } from "../src/lib/jwt";

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

  it("rejects a session access token used as a download token (iss/aud isolation)", async () => {
    // A real access token signed with the SAME key — same signature, wrong iss/aud.
    const accessToken = await signAccess(KEY, {
      userId: "user-1",
      sessionId: "session-1",
      deviceId: "device-1",
    });
    // verifyDownloadToken must reject because iss="snapceipt" / aud="snapceipt-ios"
    // don't match the download token's expected iss="snapceipt-export" / aud="snapceipt-export-dl".
    await expect(verifyDownloadToken(KEY, accessToken)).rejects.toThrow();
  });
});

describe("quote-link token", () => {
  it("round-trips quoteId + userId", async () => {
    const token = await signQuoteLinkToken(KEY, "quote-1", "user-1");
    const out = await verifyQuoteLinkToken(KEY, token);
    expect(out).toEqual({ quoteId: "quote-1", userId: "user-1" });
  });

  it("uses a 90-day TTL", () => {
    expect(QUOTE_LINK_TTL_SECONDS).toBe(90 * 24 * 60 * 60);
  });

  it("rejects an expired token", async () => {
    const token = await signQuoteLinkToken(KEY, "quote-1", "user-1", -10);
    await expect(verifyQuoteLinkToken(KEY, token)).rejects.toThrow();
  });

  it("rejects a forged token", async () => {
    await expect(verifyQuoteLinkToken(KEY, "not.a.token")).rejects.toThrow();
  });

  it("rejects a download token replayed as a quote-link token (distinct audience)", async () => {
    const { signDownloadToken } = await import("../src/lib/exportToken");
    const dl = await signDownloadToken(KEY, "u/x/quotes/y.pdf");
    await expect(verifyQuoteLinkToken(KEY, dl)).rejects.toThrow();
  });
});
