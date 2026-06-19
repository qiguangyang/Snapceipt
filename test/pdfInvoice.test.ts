import { describe, expect, it } from "vitest";
import { PDFDocument } from "pdf-lib";
import {
  buildInvoicePdf,
  gstLabel,
  INVOICE_HEADING,
  GST_REGISTERED_LABEL,
  GST_INCLUSIVE_NOTE,
  type InvoicePdfData,
  type InvoiceLineItemRow,
  type InvoiceSender,
} from "../src/lib/pdfInvoice";

const sender: InvoiceSender = { name: "Acme Pty Ltd", abn: "12 345 678 901", gstRegistered: true };

const lineItems: InvoiceLineItemRow[] = [
  { description: "Site inspection", quantity: 1, unitPriceCents: 25000 },
  { description: "Report + drawings", quantity: 2, unitPriceCents: 40000 },
];

const invoice: InvoicePdfData = {
  number: "INV-0001",
  clientName: "Jane Roe",
  clientEmail: "jane@example.com",
  gstEnabled: true,
  gstInclusive: false,
  gstRateBp: null,
  subtotalCents: 105000,
  gstCents: 10500,
  totalCents: 115500,
  issueDate: "2026-06-19",
  dueDate: "2026-07-03",
  amountPaidCents: 0,
};

describe("tax-invoice compliance strings", () => {
  it("INVOICE_HEADING contains the ATO-mandated wording", () => {
    expect(INVOICE_HEADING).toContain("Tax invoice");
  });

  it("GST_REGISTERED_LABEL contains the required registration notice", () => {
    expect(GST_REGISTERED_LABEL).toContain("Registered for GST");
  });

  it("GST_INCLUSIVE_NOTE contains the GST-inclusive disclosure", () => {
    expect(GST_INCLUSIVE_NOTE).toContain("Total price includes GST");
  });
});

describe("gstLabel — rate-aware ledger label", () => {
  it("renders the configured rate (15%)", () => {
    expect(gstLabel(1500, false)).toBe("GST (15%)");
  });

  it("renders a fractional rate (12.5%)", () => {
    expect(gstLabel(1250, false)).toBe("GST (12.5%)");
  });

  it("defaults a null rate to 10% (pre-feature invoice)", () => {
    expect(gstLabel(null, false)).toBe("GST (10%)");
    expect(gstLabel(1000, false)).toBe("GST (10%)");
  });

  it("flags the embedded portion when GST-inclusive", () => {
    expect(gstLabel(1500, true)).toBe("GST (15%) included");
  });
});

describe("buildInvoicePdf", () => {
  it("returns a real %PDF Uint8Array that opens to >=1 page", async () => {
    const bytes = await buildInvoicePdf(invoice, lineItems, sender);
    expect(bytes[0]).toBe(0x25); // %
    expect(bytes[1]).toBe(0x50); // P
    expect(bytes[2]).toBe(0x44); // D
    expect(bytes[3]).toBe(0x46); // F
    const doc = await PDFDocument.load(bytes);
    expect(doc.getPageCount()).toBeGreaterThanOrEqual(1);
  });

  it("renders with GST off, no ABN, a null number, and no due date", async () => {
    const bytes = await buildInvoicePdf(
      {
        number: null,
        clientName: "Bob",
        clientEmail: null,
        gstEnabled: false,
        gstInclusive: false,
        gstRateBp: null,
        subtotalCents: 5000,
        gstCents: 0,
        totalCents: 5000,
        issueDate: "2026-06-19",
        dueDate: null,
        amountPaidCents: 0,
      },
      [{ description: "Consult", quantity: 1, unitPriceCents: 5000 }],
      { name: "Solo Trader", abn: null, gstRegistered: false },
    );
    expect(bytes[0]).toBe(0x25);
    const doc = await PDFDocument.load(bytes);
    expect(doc.getPageCount()).toBe(1);
  });

  it("renders a GST-inclusive invoice (ex-GST subtotal + embedded GST)", async () => {
    const bytes = await buildInvoicePdf(
      { ...invoice, gstInclusive: true, subtotalCents: 95455, gstCents: 9545, totalCents: 105000 },
      lineItems,
      sender,
    );
    expect(bytes[0]).toBe(0x25);
    const doc = await PDFDocument.load(bytes);
    expect(doc.getPageCount()).toBeGreaterThanOrEqual(1);
  });

  it("renders the amount-paid / balance-due ledger on a partially-paid invoice", async () => {
    const bytes = await buildInvoicePdf({ ...invoice, amountPaidCents: 50000 }, lineItems, sender);
    expect(bytes[0]).toBe(0x25);
    const doc = await PDFDocument.load(bytes);
    expect(doc.getPageCount()).toBeGreaterThanOrEqual(1);
  });

  it("paginates a long line-item list", async () => {
    const many: InvoiceLineItemRow[] = Array.from({ length: 80 }, (_, i) => ({
      description: `Line ${i}`,
      quantity: 1,
      unitPriceCents: 1000 + i,
    }));
    const bytes = await buildInvoicePdf({ ...invoice, subtotalCents: 0, gstCents: 0, totalCents: 0 }, many, sender);
    const doc = await PDFDocument.load(bytes);
    expect(doc.getPageCount()).toBeGreaterThan(1);
  });
});
