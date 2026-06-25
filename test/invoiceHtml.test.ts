import { describe, expect, it } from "vitest";
import { renderInvoiceHtml, type InvoiceHtmlData } from "../src/lib/invoiceHtml";

function data(overrides: Partial<InvoiceHtmlData> = {}): InvoiceHtmlData {
  return {
    number: "INV-0001",
    issueDate: "2026-06-20",
    dueDate: "2026-07-04",
    clientName: "Jane Roe",
    clientEmail: "jane@example.com",
    gstEnabled: true,
    gstInclusive: false,
    gstRateBp: 1500,
    subtotalCents: 10000,
    gstCents: 1500,
    totalCents: 11500,
    amountPaidCents: 0,
    business: {
      name: "Acme Pty Ltd",
      abn: "12 345 678 901",
      businessEmail: "hi@acme.example",
      phone: "0400 000 000",
      website: "https://acme.example",
      address: "1 Main St\nSydney NSW 2000",
      bankDetails: "BSB 062-000\nAcc 1234 5678",
    },
    lineItems: [{ description: "Site inspection", quantity: 1, unitPriceCents: 10000 }],
    logoDataUri: "data:image/png;base64,AAAA",
    appUrl: "https://snapceipt.cc",
    ...overrides,
  };
}

describe("renderInvoiceHtml", () => {
  it("renders a full TAX INVOICE document with the business header", () => {
    const html = renderInvoiceHtml(data());
    expect(html.startsWith("<!doctype html>")).toBe(true);
    expect(html).toContain("TAX INVOICE");
    expect(html).toContain("Acme Pty Ltd");
    expect(html).toContain("12 345 678 901");
    expect(html).toContain("hi@acme.example");
  });

  it("shows the invoice number, bill-to, due date, and dollar total", () => {
    const html = renderInvoiceHtml(data());
    expect(html).toContain("INV-0001");
    expect(html).toContain("Jane Roe");
    expect(html).toContain("Due date");
    expect(html).toContain("2026-07-04");
    expect(html).toContain("$115.00"); // 11500c
  });

  it("labels the GST line with the document rate (15%), and 10% when null", () => {
    expect(renderInvoiceHtml(data())).toContain("GST (15%)");
    expect(renderInvoiceHtml(data({ gstRateBp: null, gstCents: 1000, totalCents: 11000 }))).toContain("GST (10%)");
  });

  it("renders the payment/bank details (multiline -> <br>) and a due note", () => {
    const html = renderInvoiceHtml(data());
    expect(html).toContain("Payment details:<br>"); // line break after the label
    expect(html).toContain("BSB 062-000<br>Acc 1234 5678");
    expect(html).toContain("Payment due by 2026-07-04");
  });

  it("has a Save as PDF button and NO Accept button (invoices are not accepted)", () => {
    const html = renderInvoiceHtml(data());
    expect(html).toContain("Save as PDF");
    expect(html).not.toContain("Accept");
    expect(html).not.toContain("/accept");
  });

  it("shows Total (not Balance due) and no Paid banner when nothing is paid", () => {
    const html = renderInvoiceHtml(data({ amountPaidCents: 0 }));
    expect(html).toContain("Total (AUD)");
    expect(html).not.toContain("Balance due");
    expect(html).not.toContain("Paid &#10003;");
  });

  it("shows Amount paid + Balance due when partially paid", () => {
    const html = renderInvoiceHtml(data({ amountPaidCents: 5000 }));
    expect(html).toContain("Amount paid");
    expect(html).toContain("Balance due (AUD)");
    expect(html).toContain("$65.00"); // 11500 - 5000 = 6500c
    expect(html).not.toContain("Paid &#10003;");
  });

  it("shows the Paid banner when payments cover the total", () => {
    const html = renderInvoiceHtml(data({ amountPaidCents: 11500 }));
    expect(html).toContain("Paid &#10003;");
    expect(html).toContain("$0.00"); // balance clamped to zero
  });

  it("falls back to 'Payment due on receipt' when no due date", () => {
    const html = renderInvoiceHtml(data({ dueDate: null }));
    expect(html).toContain("Payment due on receipt");
    expect(html).not.toContain("Due date");
  });

  it("HTML-escapes client + business fields", () => {
    const html = renderInvoiceHtml(data({ clientName: "A & B <Ltd>" }));
    expect(html).toContain("A &amp; B &lt;Ltd&gt;");
    expect(html).not.toContain("A & B <Ltd>");
  });
});
