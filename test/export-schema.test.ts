import { describe, it, expect } from "vitest";
import { exportRequestSchema } from "../src/schemas/export";

describe("exportRequestSchema — bas format", () => {
  it("accepts format 'bas' with an optional bas.paygInstalmentCents", () => {
    const r = exportRequestSchema.safeParse({
      profileId: "p", format: "bas", from: "2026-04-01", to: "2026-06-30",
      bas: { paygInstalmentCents: 50000 },
    });
    expect(r.success).toBe(true);
  });

  it("accepts format 'bas' with no bas object and no toEmail", () => {
    const r = exportRequestSchema.safeParse({
      profileId: "p", format: "bas", from: "2026-04-01", to: "2026-06-30",
    });
    expect(r.success).toBe(true);
  });

  it("rejects a non-integer paygInstalmentCents", () => {
    const r = exportRequestSchema.safeParse({
      profileId: "p", format: "bas", from: "2026-04-01", to: "2026-06-30",
      bas: { paygInstalmentCents: 1.5 },
    });
    expect(r.success).toBe(false);
  });
});
