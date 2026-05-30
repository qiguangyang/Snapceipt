// test/extractionHeuristic.test.ts
import { describe, expect, it } from "vitest";
import { heuristicExtract, type HeuristicReceipt } from "../src/lib/extractionHeuristic";

const SAMPLE = [
  "THE GROUNDS",
  "28/05/2026",
  "Flat White x2  9.00",
  "Big Brekkie 24.00",
  "GST 3.86",
  "TOTAL 42.50",
].join("\n");

describe("heuristicExtract()", () => {
  it("picks the first letter-rich line as the merchant", () => {
    const r = heuristicExtract(SAMPLE, "2026-05-30");
    expect(r.merchant).toBe("THE GROUNDS");
  });

  it("picks the largest dollar amount as the total", () => {
    const r = heuristicExtract(SAMPLE, "2026-05-30");
    expect(r.total).toBe(42.5);
  });

  it("does NOT pick a bare 4-digit year/ABN/postcode as the total (cents-bearing only, date lines skipped)", () => {
    // The date line carries 2026 and the ABN carries 12345678901 — both larger
    // than the real total (42.50), but neither has a .NN cents component and the
    // date line is skipped, so total stays 42.50.
    const withNoise = [
      "THE GROUNDS",
      "ABN 12 345 678 901",
      "28/05/2026",
      "Flat White x2  9.00",
      "Big Brekkie 24.00",
      "GST 3.86",
      "TOTAL 42.50",
    ].join("\n");
    const r = heuristicExtract(withNoise, "2026-05-30");
    expect(r.total).toBe(42.5);
  });

  it("does NOT let a year on the date line become the total even when no item is larger", () => {
    // Only a small cents-bearing total (10.00) plus a date line containing 2026.
    const r = heuristicExtract("WIDGET CO\n28/05/2026\nTOTAL 10.00", "2026-01-02");
    expect(r.total).toBe(10.0);
  });

  it("parses a DD/MM/YYYY AU date to YYYY-MM-DD", () => {
    const r = heuristicExtract(SAMPLE, "2026-05-30");
    expect(r.date).toBe("2026-05-28");
  });

  it("uses the printed GST line when present", () => {
    const r = heuristicExtract(SAMPLE, "2026-05-30");
    expect(r.gst).toBe(3.86);
  });

  it("infers GST as round(total/11) when no GST line is printed", () => {
    const noGst = ["CAFE X", "Coffee 5.00", "TOTAL 11.00"].join("\n");
    const r = heuristicExtract(noGst, "2026-05-30");
    expect(r.gst).toBe(1); // 11/11 = 1.00
  });

  it("falls back to the provided default date when none is parseable", () => {
    const r = heuristicExtract("WIDGET CO\nTOTAL 10.00", "2026-01-02");
    expect(r.date).toBe("2026-01-02");
  });

  it("always returns category 'office' and deductible 100 (the safe fallback)", () => {
    const r = heuristicExtract(SAMPLE, "2026-05-30");
    expect(r.category).toBe("office");
    expect(r.deductible).toBe(100);
  });

  it("extracts line items as {name, price} pairs (excludes the GST/TOTAL summary lines)", () => {
    const r = heuristicExtract(SAMPLE, "2026-05-30");
    const names = r.lineItems.map((li) => li.name);
    expect(names).toContain("Flat White x2");
    expect(names).toContain("Big Brekkie");
    expect(names).not.toContain("TOTAL");
    expect(names).not.toContain("GST");
  });

  it("never returns a negative total and clamps empty input to a zero receipt", () => {
    const r = heuristicExtract("", "2026-05-30");
    expect(r.total).toBe(0);
    expect(r.gst).toBe(0);
    expect(r.merchant).toBe("");
    expect(r.lineItems).toEqual([]);
  });

  it("rounds GST to cents", () => {
    const r = heuristicExtract("SHOP\nTOTAL 100.00", "2026-05-30");
    expect(r.gst).toBe(9.09); // 100/11 = 9.0909 -> 9.09
  });
});

// Type guard: the shape the stub + fallback consume.
const _typecheck: HeuristicReceipt = {
  merchant: "",
  date: "2026-05-30",
  total: 0,
  gst: 0,
  category: "office",
  deductible: 100,
  lineItems: [],
};
void _typecheck;
