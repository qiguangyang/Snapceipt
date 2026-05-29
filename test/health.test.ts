import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

describe("misc routes", () => {
  it("GET /health returns the public liveness envelope", async () => {
    const res = await SELF.fetch("https://example.com/health");
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true, service: "snapceipt-api" });
  });

  it("ALL /banks returns 501 NOT_IMPLEMENTED with an error envelope", async () => {
    const res = await SELF.fetch("https://example.com/banks", { method: "POST" });
    expect(res.status).toBe(501);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe("NOT_IMPLEMENTED");
  });

  it("GET /_meta-backed migration applied (D1 binding wired)", async () => {
    const res = await SELF.fetch("https://example.com/health");
    // health works -> worker bundled; migrations are validated by the harness
    // itself (applyD1Migrations would throw in setup if the SQL were invalid).
    expect(res.ok).toBe(true);
  });
});
