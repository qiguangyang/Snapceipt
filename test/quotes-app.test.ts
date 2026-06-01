import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

describe("/quotes (through the real app)", () => {
  it("requires auth (401 without a bearer token)", async () => {
    const res = await SELF.fetch("https://x/quotes/some-id/send", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{}",
    });
    expect(res.status).toBe(401);
  });

  it("GET /quotes/dl/* is public (no auth) — a forged token is 403, not 401", async () => {
    const res = await SELF.fetch("https://x/quotes/dl/forged");
    expect(res.status).toBe(403);
  });
});
