/**
 * Unit tests for sendQuoteEmail — the link-only variant (no PDF attachment).
 * sendQuoteEmail now uses the plain-text SendEmail builder path (like
 * sendMagicLinkEmail), so we capture the builder object passed to env.EMAIL.send
 * and assert the link + subject + reply-to, with no attachments.
 */
import { afterEach, describe, expect, it, vi } from "vitest";
import { sendQuoteEmail } from "../src/lib/email";

afterEach(() => {
  vi.restoreAllMocks();
});

describe("sendQuoteEmail", () => {
  it("calls env.EMAIL.send once with the client envelope + reply-to + no attachment", async () => {
    const sent: any[] = [];
    const fakeEnv = { EMAIL: { send: async (m: unknown) => { sent.push(m); } } } as any;
    await sendQuoteEmail(fakeEnv, {
      to: "jane@client.au",
      replyTo: "trader@example.com",
      quoteNumber: "SN-0001",
      clientName: "Jane Roe",
      totalCents: 115500,
      url: "https://api.snapceipt.cc/q/sometoken",
    });
    expect(sent.length).toBe(1);
    const msg = sent[0];
    expect(msg.to).toBe("jane@client.au");
    expect(msg.from.email).toBe("noreply@snapceipt.cc");
    expect(msg.replyTo).toBe("trader@example.com");
    expect(msg.attachments).toBeUndefined();
  });

  it("the message text carries the hosted link + the quote-number subject", async () => {
    const sent: any[] = [];
    const fakeEnv = { EMAIL: { send: async (m: unknown) => { sent.push(m); } } } as any;
    await sendQuoteEmail(fakeEnv, {
      to: "jane@client.au",
      replyTo: "trader@example.com",
      quoteNumber: "SN-0001",
      clientName: "Jane Roe",
      totalCents: 115500,
      url: "https://api.snapceipt.cc/q/sometoken",
    });
    const msg = sent[0];
    expect(msg.subject).toContain("SN-0001");
    expect(msg.text).toContain("https://api.snapceipt.cc/q/sometoken");
    expect(msg.text).toContain("Hi Jane Roe,");
    expect(msg.text).not.toContain("attached");
  });
});
