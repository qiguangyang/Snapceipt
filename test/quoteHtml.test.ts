import { describe, expect, it } from "vitest";
import { renderQuoteHtml, type QuoteHtmlData } from "../src/lib/quoteHtml";

function data(overrides: Partial<QuoteHtmlData> = {}): QuoteHtmlData {
  return {
    number: "SN-0001",
    issuedDate: "2026-06-20",
    validUntil: "2026-07-04",
    clientName: "Jane Roe",
    clientEmail: "jane@example.com",
    clientAddress: "9 Client Rd\nMelbourne VIC 3000",
    clientMobile: "0411 222 333",
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
  it("escapes a malicious line-item quantity (XSS guard, M1)", () => {
    // quantity is typed number but read from D1, where /sync/push can store a string;
    // the renderer must escape it at the sink.
    const html = renderQuoteHtml(
      data({ lineItems: [{ description: "x", quantity: "<img src=x onerror=alert(1)>" as unknown as number, unitPriceCents: 100 }] }),
    );
    expect(html).not.toContain("<img src=x onerror=alert(1)>");
    expect(html).toContain("&lt;img src=x onerror=alert(1)&gt;");
  });

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

  it("renders the client address (multiline -> <br>) in the To block when set", () => {
    const html = renderQuoteHtml(data());
    expect(html).toContain("9 Client Rd<br>Melbourne VIC 3000");
  });

  it("omits the client address when null", () => {
    const html = renderQuoteHtml(data({ clientAddress: null }));
    expect(html).not.toContain("9 Client Rd");
    expect(html).not.toContain("Melbourne VIC 3000");
  });

  it("renders the client mobile in the To block when set", () => {
    expect(renderQuoteHtml(data())).toContain("0411 222 333");
  });

  it("omits the client mobile when null", () => {
    expect(renderQuoteHtml(data({ clientMobile: null }))).not.toContain("0411 222 333");
  });

  it("inlines the logo data-URI in an <img>", () => {
    expect(renderQuoteHtml(data())).toContain("data:image/png;base64,AAAA");
  });

  it("renders the payment-details block (label on its own line) when bankDetails is set", () => {
    const html = renderQuoteHtml(data());
    expect(html).toContain("Payment details:<br>"); // line break after the label
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

  it("renders the redesigned layout (QUOTE title, table headers, terms, signature)", () => {
    const html = renderQuoteHtml(data());
    expect(html).toContain(">QUOTE<");
    expect(html).toContain(">QTY<");
    expect(html).toContain(">Description<");
    expect(html).toContain(">Unit Price<");
    expect(html).toContain(">Amount<");
    expect(html).toContain("Terms and Conditions");
    expect(html).toContain("customer signature");
    expect(html).toContain("Total (AUD)");
  });

  it("shows the To label + Quote # / Quote date / Due date meta rows", () => {
    const html = renderQuoteHtml(data());
    expect(html).toContain(">To<");
    expect(html).toContain("Quote #");
    expect(html).toContain("Quote date");
    expect(html).toContain("Due date");
    expect(html).toContain("2026-06-20"); // quote date
    expect(html).toContain("2026-07-04"); // due date (validUntil)
  });

  it("omits the Due date row when there is no validUntil", () => {
    const html = renderQuoteHtml(data({ validUntil: null }));
    expect(html).not.toContain("Due date");
  });

  it("renders the unit price bare and the line amount with a $ sign", () => {
    const html = renderQuoteHtml(data()); // 1 × $100.00
    expect(html).toContain(">100.00<"); // unit price column, no $
    expect(html).toContain("$100.00");  // amount column, with $
  });
});

 describe("saved-item units", () => {
  it("renders and escapes units alongside descriptions", () => {
    const html = renderQuoteHtml(data({ lineItems: [{ description: "Work", unitLabel: "hour <script>", quantity: 1, unitPriceCents: 100 }] }));
    expect(html).toContain("hour &lt;script&gt;");
    expect(html).not.toContain("hour <script>");
  });
  it("null unit preserves legacy output", () => {
    const line = { description: "Work", quantity: 1, unitPriceCents: 100 };
    expect(renderQuoteHtml(data({ lineItems: [{ ...line, unitLabel: null }] }))).toBe(renderQuoteHtml(data({ lineItems: [line] })));
  });
});
