// test/rateLimit-extract.test.ts
import { describe, expect, it } from "vitest";
import { RATE_LIMIT_TIERS, rateLimit } from "../src/middleware/rateLimit";

describe("extract rate tier", () => {
  it("declares a 30/user/hr extract tier", () => {
    const t = RATE_LIMIT_TIERS.extract;
    expect(t).toBeDefined();
    expect(t.limit).toBe(30);
    expect(t.windowMs).toBe(3_600_000);
    expect(t.dimension).toBe("user");
    expect(t.name).toBe("extract");
  });

  it('rateLimit("extract") is constructible (kind is in the union)', () => {
    const mw = rateLimit("extract");
    expect(typeof mw).toBe("function");
  });
});
