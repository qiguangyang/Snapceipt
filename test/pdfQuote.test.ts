import { describe, expect, it } from "vitest";
import { PDFDocument } from "pdf-lib";
import { buildQuotePdf, type QuotePdfData, type QuoteLineItemRow, type QuoteSender } from "../src/lib/pdfQuote";

const sender: QuoteSender = { name: "Acme Pty Ltd", abn: "12 345 678 901", gstRegistered: true };

const lineItems: QuoteLineItemRow[] = [
  { description: "Site inspection", quantity: 1, unitPriceCents: 25000 },
  { description: "Report + drawings", quantity: 2, unitPriceCents: 40000 },
];

const quote: QuotePdfData = {
  number: "SN-0001",
  clientName: "Jane Roe",
  clientEmail: "jane@example.com",
  gstEnabled: true,
  subtotalCents: 105000,
  gstCents: 10500,
  totalCents: 115500,
  validUntil: "2026-06-15",
  issuedDate: "2026-06-01",
};

describe("buildQuotePdf", () => {
  it("returns a real %PDF Uint8Array that opens to >=1 page", async () => {
    const bytes = await buildQuotePdf(quote, lineItems, sender);
    expect(bytes[0]).toBe(0x25);
    expect(bytes[1]).toBe(0x50);
    expect(bytes[2]).toBe(0x44);
    expect(bytes[3]).toBe(0x46);
    const doc = await PDFDocument.load(bytes);
    expect(doc.getPageCount()).toBeGreaterThanOrEqual(1);
  });

  it("renders with GST off, no ABN, a null number, and no validUntil", async () => {
    const bytes = await buildQuotePdf(
      {
        number: null,
        clientName: "Bob",
        clientEmail: null,
        gstEnabled: false,
        subtotalCents: 5000,
        gstCents: 0,
        totalCents: 5000,
        validUntil: null,
        issuedDate: "2026-06-01",
      },
      [{ description: "Consult", quantity: 1, unitPriceCents: 5000 }],
      { name: "Solo Trader", abn: null, gstRegistered: false },
    );
    expect(bytes[0]).toBe(0x25);
    const doc = await PDFDocument.load(bytes);
    expect(doc.getPageCount()).toBe(1);
  });

  it("paginates a long line-item list", async () => {
    const many: QuoteLineItemRow[] = Array.from({ length: 80 }, (_, i) => ({
      description: `Line ${i}`,
      quantity: 1,
      unitPriceCents: 1000 + i,
    }));
    const bytes = await buildQuotePdf({ ...quote, subtotalCents: 0, gstCents: 0, totalCents: 0 }, many, sender);
    const doc = await PDFDocument.load(bytes);
    expect(doc.getPageCount()).toBeGreaterThan(1);
  });
});
