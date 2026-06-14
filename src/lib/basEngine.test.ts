import { describe, it, expect } from "vitest";
import golden from "../../test/fixtures/bas-golden.json";
import { basEngine, CAPITAL_THRESHOLD_CENTS, type BasTxn } from "./basEngine";

describe("basEngine — golden vectors (spec §4.3)", () => {
  it("fixture is version 1 (guard against silent drift)", () => {
    expect(golden.version).toBe(1);
  });

  it("exports the ATO capital threshold as $1,000 (shared with csvBas)", () => {
    expect(CAPITAL_THRESHOLD_CENTS).toBe(100000);
  });

  for (const sc of golden.scenarios) {
    it(`matches golden vector: ${sc.name}`, () => {
      const out = basEngine(sc.txns as BasTxn[], {
        gstRegistered: sc.gstRegistered,
        manual: sc.manual,
      });
      expect(out).toEqual(sc.expected);
    });
  }
});

describe("basEngine — capital $1,000 threshold (spec §4.3 G10)", () => {
  it("a capital purchase of exactly $1,000 falls to G11, not G10", () => {
    const out = basEngine(
      [{ amountCents: -100000, gstFree: false, capital: true }],
      { gstRegistered: true, manual: { paygInstalmentCents: 0 } },
    );
    expect(out.g10).toBe(0);
    expect(out.g11).toBe(100000);
  });

  it("a capital purchase of $1,000.01 lands in G10", () => {
    const out = basEngine(
      [{ amountCents: -100001, gstFree: false, capital: true }],
      { gstRegistered: true, manual: { paygInstalmentCents: 0 } },
    );
    expect(out.g10).toBe(100001);
    expect(out.g11).toBe(0);
  });
});
