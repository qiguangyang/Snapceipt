// test/extractionHeuristic.test.ts
import { describe, expect, it } from "vitest";
import { heuristicExtract, type HeuristicReceipt } from "../src/lib/extractionHeuristic";
import corpusRaw from "./fixtures/heuristic-receipts.json";

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

  it("returns deductible 100", () => {
    const r = heuristicExtract(SAMPLE, "2026-05-30");
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

  it("prefers an explicit TOTAL line over a larger CASH tendered line", () => {
    const r = heuristicExtract("Cafe Norm\nFlat White 4.50\nTOTAL 4.50\nCASH 50.00\nCHANGE 45.50", "2026-06-15");
    expect(r.total).toBe(4.5);
  });

  it("ignores tender lines when no explicit total is present", () => {
    const r = heuristicExtract("Shop\nItem 9.00\nCASH 50.00\nCHANGE 41.00", "2026-06-15");
    expect(r.total).toBe(9); // largest non-tender cents amount
  });

  it("infers category from the merchant", () => {
    expect(heuristicExtract("WOOLWORTHS 123\nTOTAL 12.00", "2026-06-15").category).toBe("groceries");
    expect(heuristicExtract("Shell Express\nTOTAL 80.00", "2026-06-15").category).toBe("fuel");
  });

  it("grades confidence: total line + printed gst + known merchant", () => {
    const r = heuristicExtract("WOOLWORTHS\nTOTAL 11.00\nGST 1.00\non 15/06/2026", "2026-06-15");
    expect(r.confidence).toBeGreaterThanOrEqual(0.6);
    expect(r.needsReview).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// Shared golden corpus: both Swift and TS parsers must satisfy these cases.
// The corpus is the contract — if a case fails, fix the parser, not the corpus.
// ---------------------------------------------------------------------------
// Imported as a static module (JSON import) — the @cloudflare/vitest-pool-workers
// runtime doesn't support node:fs readFileSync, but Vite's JSON plugin works fine.
const corpus = corpusRaw as Array<{
  name: string;
  ocrText: string;
  expect: { merchant: string; date: string | null; total: number; gst: number; category: string };
}>;

describe("shared heuristic corpus", () => {
  for (const c of corpus) {
    it(c.name, () => {
      const r = heuristicExtract(c.ocrText, "2026-01-01");
      expect(r.merchant).toBe(c.expect.merchant);
      if (c.expect.date) expect(r.date).toBe(c.expect.date);
      expect(r.total).toBe(c.expect.total);
      expect(r.gst).toBe(c.expect.gst);
      expect(r.category).toBe(c.expect.category);
    });
  }
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
  confidence: 0.3,
  needsReview: true,
};
void _typecheck;
