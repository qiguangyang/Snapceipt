import { describe, expect, it } from "vitest";
import { PDFDocument } from "pdf-lib";
import {
  buildInvoicePdf,
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
  subtotalCents: 105000,
  gstCents: 10500,
  totalCents: 115500,
  issueDate: "2026-06-19",
  dueDate: "2026-07-03",
  amountPaidCents: 0,
};

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
