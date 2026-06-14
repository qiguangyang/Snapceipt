import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

describe("/appstore (through the real app)", () => {
  it("POST /appstore/notifications is public (no bearer required)", async () => {
    const res = await SELF.fetch("https://x/appstore/notifications", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({}),
    });
    // Public route reached -> validation runs -> 400 (NOT 401 auth).
    expect(res.status).toBe(400);
  });
});
