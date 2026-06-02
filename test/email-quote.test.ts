/**
 * Unit tests for sendQuoteEmail — mirrors test/email.test.ts. Stubs
 * cloudflare:email so we can capture the raw MIME + envelope addresses without
 * a live binding, and exercises the MIME build with a fake env.EMAIL.send.
 */
import { afterEach, describe, expect, it, vi } from "vitest";
import { sendQuoteEmail } from "../src/lib/email";

const captured = vi.hoisted(() => ({
  raw: null as string | null,
  from: null as string | null,
  to: null as string | null,
}));

vi.mock("cloudflare:email", () => {
  return {
    EmailMessage: class MockEmailMessage {
      readonly from: string;
      readonly to: string;
      constructor(from: string, to: string, raw: string) {
        this.from = from;
        this.to = to;
        captured.raw = typeof raw === "string" ? raw : String(raw);
        captured.from = from;
        captured.to = to;
      }
    },
  };
});

afterEach(() => {
  vi.restoreAllMocks();
  captured.raw = null;
  captured.from = null;
  captured.to = null;
});

describe("sendQuoteEmail", () => {
  it("calls env.EMAIL.send once with the client envelope addresses", async () => {
    const sent: unknown[] = [];
    const fakeEnv = { EMAIL: { send: async (m: unknown) => { sent.push(m); } } } as any;
    await sendQuoteEmail(fakeEnv, {
      to: "jane@client.au",
      replyTo: "trader@example.com",
      quoteNumber: "SN-0001",
      clientName: "Jane Roe",
      totalCents: 115500,
      pdf: new Uint8Array([0x25, 0x50, 0x44, 0x46, 1, 2, 3]),
    });
    expect(sent.length).toBe(1);
    expect(captured.from).toBe("noreply@snapceipt.cc");
    expect(captured.to).toBe("jane@client.au");
  });

  it("raw MIME carries the PDF attachment + the reply-to + the quote number subject", async () => {
    const fakeEnv = { EMAIL: { send: async () => {} } } as any;
    await sendQuoteEmail(fakeEnv, {
      to: "jane@client.au",
      replyTo: "trader@example.com",
      quoteNumber: "SN-0001",
      clientName: "Jane Roe",
      totalCents: 115500,
      pdf: new Uint8Array([0x25, 0x50, 0x44, 0x46, 1, 2, 3]),
    });
    const raw = captured.raw;
    expect(raw).not.toBeNull();
    expect(raw).toContain("application/pdf");
    expect(raw).toContain("quote-SN-0001.pdf");
    expect(raw).toContain("trader@example.com"); // Reply-To
    expect(raw).toContain("SN-0001"); // subject
  });
});
