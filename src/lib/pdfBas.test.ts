import { describe, it, expect } from "vitest";
import { PDFDocument } from "pdf-lib";
import { buildBasPdf, BAS_DISCLAIMER } from "./pdfBas";
import { basEngine } from "./basEngine";

const bas = basEngine(
  [
    { amountCents: 1100000, gstFree: false, capital: false },
    { amountCents: -110000, gstFree: false, capital: false },
    { amountCents: -220000, gstFree: false, capital: true },
    { amountCents: -33000, gstFree: true, capital: false },
  ],
  { gstRegistered: true, manual: { paygInstalmentCents: 0 } },
);

describe("buildBasPdf", () => {
  it("emits a real %PDF byte stream that pdf-lib can re-open", async () => {
    const bytes = await buildBasPdf({
      profileName: "Acme Pty Ltd",
      abn: "12 345 678 901",
      periodLabel: "2026-04-01 to 2026-06-30",
      bas,
    });
    expect(bytes[0]).toBe(0x25); // %
    expect(bytes[1]).toBe(0x50); // P
    const reopened = await PDFDocument.load(bytes);
    expect(reopened.getPageCount()).toBeGreaterThan(0);
  });

  it("exports the verbatim disclaimer string (spec §4.5a)", () => {
    expect(BAS_DISCLAIMER).toContain("Simpler BAS summary (G1, 1A, 1B)");
    expect(BAS_DISCLAIMER).toContain("not tax advice and has not been lodged with the ATO");
    expect(BAS_DISCLAIMER).toContain("Check against your ATO BAS form before lodging.");
  });
});
