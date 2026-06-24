/**
 * Unit tests for sendQuoteEmail — the link-only variant (no PDF attachment).
 * sendQuoteEmail uses the SendEmail builder overload's html + text fields (no
 * mimetext), so we capture the builder object passed to env.EMAIL.send and assert
 * the rich HTML body + plain-text fallback + subject + reply-to, with no attachments.
 */
import { afterEach, describe, expect, it, vi } from "vitest";
import { sendQuoteEmail, type QuoteEmail } from "../src/lib/email";

afterEach(() => {
  vi.restoreAllMocks();
});

function payload(overrides: Partial<QuoteEmail> = {}): QuoteEmail {
  return {
    to: "jane@client.au",
    replyTo: "trader@example.com",
    quoteNumber: "SN-0001",
    clientName: "Jane Roe",
    totalCents: 115500,
    url: "https://api.snapceipt.cc/q/sometoken",
    business: {
      name: "Acme Pty Ltd",
      logoR2Key: "user/profiles/p1/logo",
      abn: "12 345 678 901",
      contact: "hi@acme.example · 0400 000 000",
    },
    lineItems: [
      { description: "Site inspection", quantity: 1, amountCents: 25000 },
      { description: "Report", quantity: 2, amountCents: 80000 },
    ],
    subtotalCents: 105000,
    gstCents: 10500,
    gstEnabled: true,
    validUntil: "2026-07-04",
    appUrl: "https://snapceipt.cc",
    ...overrides,
  };
}

describe("sendQuoteEmail", () => {
  it("calls env.EMAIL.send once with the client envelope + reply-to + no attachment", async () => {
    const sent: any[] = [];
    const fakeEnv = { EMAIL: { send: async (m: unknown) => { sent.push(m); } } } as any;
    await sendQuoteEmail(fakeEnv, payload());
    expect(sent.length).toBe(1);
    const msg = sent[0];
    expect(msg.to).toBe("jane@client.au");
    expect(msg.from.email).toBe("noreply@snapceipt.cc");
    expect(msg.replyTo).toBe("trader@example.com");
    expect(msg.attachments).toBeUndefined();
  });

  it("subject is 'Your quote from <business>' (falls back to quote # when name empty)", async () => {
    const sent: any[] = [];
    const fakeEnv = { EMAIL: { send: async (m: unknown) => { sent.push(m); } } } as any;
    await sendQuoteEmail(fakeEnv, payload());
    expect(sent[0].subject).toBe("Your quote from Acme Pty Ltd");

    sent.length = 0;
    await sendQuoteEmail(fakeEnv, payload({ business: { name: "  ", logoR2Key: null, abn: null, contact: null } }));
    expect(sent[0].subject).toBe("Your quote SN-0001");
  });

  it("the plain-text fallback carries the hosted link + greeting + Snapceipt footer, no 'attached'", async () => {
    const sent: any[] = [];
    const fakeEnv = { EMAIL: { send: async (m: unknown) => { sent.push(m); } } } as any;
    await sendQuoteEmail(fakeEnv, payload());
    const msg = sent[0];
    expect(msg.text).toContain("https://api.snapceipt.cc/q/sometoken");
    expect(msg.text).toContain("Hi Jane Roe,");
    expect(msg.text).toContain("Powered by Snapceipt");
    expect(msg.text).not.toContain("attached");
  });

  it("the rich HTML body has the logo R2 url, line items, totals, accept button, and footer", async () => {
    const sent: any[] = [];
    const fakeEnv = { EMAIL: { send: async (m: unknown) => { sent.push(m); } } } as any;
    await sendQuoteEmail(fakeEnv, payload());
    const html = sent[0].html as string;
    // Logo via R2 image URL (NOT a data-URI).
    expect(html).toContain("https://api.snapceipt.cc/images/user/profiles/p1/logo");
    expect(html).not.toContain("data:image");
    // Business header + line items + totals.
    expect(html).toContain("Acme Pty Ltd");
    expect(html).toContain("Site inspection");
    expect(html).toContain("Report");
    expect(html).toContain("$1050.00"); // subtotal
    expect(html).toContain("$105.00");  // GST
    expect(html).toContain("$1155.00"); // total
    // Accept CTA + valid-until + footer.
    expect(html).toContain("https://api.snapceipt.cc/q/sometoken");
    expect(html).toContain("accept online");
    expect(html).toContain("Valid until 2026-07-04");
    expect(html).toContain("Powered by Snapceipt");
  });

  it("omits the GST row when gstEnabled is false", async () => {
    const sent: any[] = [];
    const fakeEnv = { EMAIL: { send: async (m: unknown) => { sent.push(m); } } } as any;
    await sendQuoteEmail(fakeEnv, payload({ gstEnabled: false }));
    expect(sent[0].html).not.toContain(">GST<");
  });
});
