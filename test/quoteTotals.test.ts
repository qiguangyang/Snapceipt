import { describe, expect, it } from "vitest";
import { recomputeTotals, type QuoteLineItemAmounts } from "../src/lib/quoteTotals";

const lines = (...pairs: Array<[qty: number, unit: number]>): QuoteLineItemAmounts[] =>
  pairs.map(([quantity, unitPriceCents]) => ({ quantity, unitPriceCents }));

describe("recomputeTotals", () => {
  it("sums quantity x unitPrice for the subtotal", () => {
    const t = recomputeTotals(lines([2, 5000], [1, 3000]), false);
    expect(t.subtotalCents).toBe(13000);
  });

  it("adds 10% GST (rounded) when gstEnabled", () => {
    const t = recomputeTotals(lines([1, 10000]), true);
    expect(t.subtotalCents).toBe(10000);
    expect(t.gstCents).toBe(1000);
    expect(t.totalCents).toBe(11000);
  });

  it("rounds GST to the nearest cent", () => {
    const t = recomputeTotals(lines([1, 9999]), true);
    expect(t.subtotalCents).toBe(9999);
    expect(t.gstCents).toBe(1000);
    expect(t.totalCents).toBe(10999);
  });

  it("zeroes GST when gstEnabled is false", () => {
    const t = recomputeTotals(lines([3, 2500]), false);
    expect(t.subtotalCents).toBe(7500);
    expect(t.gstCents).toBe(0);
    expect(t.totalCents).toBe(7500);
  });

  it("returns all-zero for no line items", () => {
    const t = recomputeTotals([], true);
    expect(t).toEqual({ subtotalCents: 0, gstCents: 0, totalCents: 0 });
  });

  describe("GST inclusive", () => {
    it("treats entered prices as GST-inclusive: total stays the entered sum", () => {
      // 16500 + 4500 = 21000 entered; GST = round(21000 * 0.1/1.1) = 1909.
      const t = recomputeTotals(lines([1, 16500], [1, 4500]), true, true);
      expect(t.totalCents).toBe(21000); // unchanged from entered sum
      expect(t.gstCents).toBe(1909); // embedded GST
      expect(t.subtotalCents).toBe(19091); // ex-GST base = total - gst
      expect(t.subtotalCents + t.gstCents).toBe(t.totalCents); // invariant
    });

    it("extracts a clean 1/11 when the inclusive total divides evenly", () => {
      const t = recomputeTotals(lines([1, 11000]), true, true);
      expect(t.totalCents).toBe(11000);
      expect(t.gstCents).toBe(1000);
      expect(t.subtotalCents).toBe(10000);
    });

    it("ignores gstInclusive when gstEnabled is false", () => {
      const t = recomputeTotals(lines([1, 11000]), false, true);
      expect(t).toEqual({ subtotalCents: 11000, gstCents: 0, totalCents: 11000 });
    });

    it("defaults to exclusive when gstInclusive is omitted", () => {
      const t = recomputeTotals(lines([1, 10000]), true);
      expect(t).toEqual({ subtotalCents: 10000, gstCents: 1000, totalCents: 11000 });
    });
  });
});
