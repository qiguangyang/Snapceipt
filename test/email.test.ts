/**
 * Unit tests for src/lib/email.ts — sendExportEmail.
 *
 * Strategy: exercise sendExportEmail with a stub env.EMAIL.send binding (so
 * the mimetext MIME-building code actually runs) while mocking the
 * cloudflare:email module so we can (a) construct an EmailMessage without a
 * live binding and (b) capture the raw MIME string passed to its constructor
 * to assert both attachments are present.
 */
import { afterEach, describe, expect, it, vi } from "vitest";
import { sendExportEmail } from "../src/lib/email";

// ---------------------------------------------------------------------------
// Module mock for cloudflare:email — hoisted before any imports are resolved.
// Captures the raw MIME string so we can assert attachment content-types.
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// sendExportEmail tests
// ---------------------------------------------------------------------------

describe("sendExportEmail", () => {
  it("calls env.EMAIL.send once with an EmailMessage whose from/to are correct", async () => {
    const sent: unknown[] = [];
    const fakeEnv = {
      EMAIL: { send: async (m: unknown) => { sent.push(m); } },
    } as any;

    await sendExportEmail(fakeEnv, {
      to: "cpa@firm.au",
      replyTo: "user@example.com",
      profileName: "Acme Pty Ltd",
      periodLabel: "FY2025-26",
      csv: "date,merchant\n2026-06-01,Cafe",
      pdf: new Uint8Array([0x25, 0x50, 0x44, 0x46, 1, 2, 3]),
    });

    // env.EMAIL.send was called exactly once.
    expect(sent.length).toBe(1);

    // The EmailMessage was constructed with the expected envelope addresses.
    expect(captured.from).toBe("noreply@snapceipt.app");
    expect(captured.to).toBe("cpa@firm.au");
  });

  it("raw MIME includes both attachment content-types and filenames", async () => {
    const fakeEnv = {
      EMAIL: { send: async () => {} },
    } as any;

    await sendExportEmail(fakeEnv, {
      to: "cpa@firm.au",
      replyTo: "user@example.com",
      profileName: "Acme Pty Ltd",
      periodLabel: "FY2025-26",
      csv: "date,merchant\n2026-06-01,Cafe",
      pdf: new Uint8Array([0x25, 0x50, 0x44, 0x46, 1, 2, 3]),
    });

    const raw = captured.raw;
    expect(raw).not.toBeNull();

    // Both attachment content-types must appear in the raw MIME.
    expect(raw).toContain("text/csv");
    expect(raw).toContain("application/pdf");

    // Both attachment filenames must appear.
    expect(raw).toContain("snapceipt-export.csv");
    expect(raw).toContain("snapceipt-summary.pdf");
  });

  it("throws when combined attachment size exceeds 25 MiB", async () => {
    const fakeEnv = {
      EMAIL: { send: async () => {} },
    } as any;

    const bigPdf = new Uint8Array(26 * 1024 * 1024); // 26 MiB

    await expect(
      sendExportEmail(fakeEnv, {
        to: "cpa@firm.au",
        replyTo: "user@example.com",
        profileName: "Acme Pty Ltd",
        periodLabel: "FY2025-26",
        csv: "a,b",
        pdf: bigPdf,
      }),
    ).rejects.toThrow("exceed");
  });
});
