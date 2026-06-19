import { describe, expect, it } from "vitest";
import { renderQuoteHtml, type QuoteHtmlData } from "../src/lib/quoteHtml";

function data(overrides: Partial<QuoteHtmlData> = {}): QuoteHtmlData {
  return {
    number: "SN-0001",
    issuedDate: "2026-06-20",
    validUntil: "2026-07-04",
    clientName: "Jane Roe",
    clientEmail: "jane@example.com",
    gstEnabled: true,
    gstInclusive: false,
    gstRateBp: 1500,
    subtotalCents: 10000,
    gstCents: 1500,
    totalCents: 11500,
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

describe("renderQuoteHtml", () => {
  it("renders a full HTML document with the business header fields", () => {
    const html = renderQuoteHtml(data());
    expect(html.startsWith("<!doctype html>")).toBe(true);
    expect(html).toContain("Acme Pty Ltd");
    expect(html).toContain("12 345 678 901");
    expect(html).toContain("hi@acme.example");
    expect(html).toContain("0400 000 000");
    expect(html).toContain("acme.example");
  });

  it("labels the GST line with the document rate (15%)", () => {
    expect(renderQuoteHtml(data())).toContain("GST (15%)");
  });

  it("labels GST as 10% when the rate is null", () => {
    expect(renderQuoteHtml(data({ gstRateBp: null, gstCents: 1000, totalCents: 11000 }))).toContain("GST (10%)");
  });

  it("shows the quote number, bill-to, and money formatted as dollars", () => {
    const html = renderQuoteHtml(data());
    expect(html).toContain("SN-0001");
    expect(html).toContain("Jane Roe");
    expect(html).toContain("$115.00"); // total 11500c
  });

  it("inlines the logo data-URI in an <img>", () => {
    expect(renderQuoteHtml(data())).toContain("data:image/png;base64,AAAA");
  });

  it("renders the payment-details block when bankDetails is set", () => {
    const html = renderQuoteHtml(data());
    expect(html).toContain("Payment details");
    expect(html).toContain("BSB 062-000");
  });

  it("omits the payment-details block when bankDetails is null", () => {
    const b = data().business;
    const html = renderQuoteHtml(data({ business: { ...b, bankDetails: null } }));
    expect(html).not.toContain("Payment details");
  });

  it("includes the Made-with-Snapceipt badge linking to the app", () => {
    const html = renderQuoteHtml(data());
    expect(html).toContain("Made with Snapceipt");
    expect(html).toContain("https://snapceipt.cc");
  });

  it("escapes HTML in user fields (no script injection)", () => {
    const html = renderQuoteHtml(data({ clientName: "<script>alert(1)</script>" }));
    expect(html).not.toContain("<script>alert(1)</script>");
    expect(html).toContain("&lt;script&gt;");
  });

  it("hides the GST line entirely when gstEnabled is false", () => {
    const html = renderQuoteHtml(data({ gstEnabled: false, gstCents: 0, totalCents: 10000 }));
    expect(html).not.toContain("GST (");
  });
});
