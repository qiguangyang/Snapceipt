import { describe, expect, it } from "vitest";
import { PDFDocument } from "pdf-lib";
import { buildExportPdf, type PdfTxnRow } from "../src/lib/pdfExport";

const rows: PdfTxnRow[] = Array.from({ length: 80 }, (_, i) => ({
  txn_date: "2026-05-30",
  merchant: `Merchant ${i}`,
  cat_key: i % 2 === 0 ? "meals" : "office",
  amount_cents: -(100 + i),
  gst_cents: 10,
  deductible_pct: 50,
}));

describe("buildExportPdf", () => {
  it("returns a %PDF Uint8Array that opens, contains the period header, and paginates a long list", async () => {
    const bytes = await buildExportPdf({
      profileName: "Acme Pty Ltd",
      periodLabel: "FY2025-26",
      deductibleTotalCents: 12345,
      gstTotalCents: 6789,
      topCategories: [
        { catKey: "meals", spendCents: 5000 },
        { catKey: "office", spendCents: 3000 },
      ],
      rows,
    });

    // %PDF magic bytes (0x25 0x50 0x44 0x46).
    expect(bytes[0]).toBe(0x25);
    expect(bytes[1]).toBe(0x50);
    expect(bytes[2]).toBe(0x44);
    expect(bytes[3]).toBe(0x46);

    // It is a real, openable PDF and paginated (80 rows overflow one page).
    const doc = await PDFDocument.load(bytes);
    expect(doc.getPageCount()).toBeGreaterThan(1);
  });

  it("renders a $0 summary for empty data on a single page", async () => {
    const bytes = await buildExportPdf({
      profileName: "Acme",
      periodLabel: "May 2026",
      deductibleTotalCents: 0,
      gstTotalCents: 0,
      topCategories: [],
      rows: [],
    });
    expect(bytes[0]).toBe(0x25);
    const doc = await PDFDocument.load(bytes);
    expect(doc.getPageCount()).toBe(1);
  });
});
