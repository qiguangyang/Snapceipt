import { PDFDocument, StandardFonts, rgb, type PDFFont } from "pdf-lib";
import type { BasResult } from "./basEngine";

/**
 * BAS summary PDF (spec §4.5a). Clones pdfExport.ts: pdf-lib A4 portrait,
 * standard Helvetica, no embedded images — pure-JS, Workers-safe. Two sections:
 * (1) "Lodge these on your BAS" = the Simpler BAS spine the user files (G1, 1A,
 * 1B → net 9, PAYG 5A, total); (2) "Working papers (not entered on Simpler BAS)"
 * = the full G2–G20 worksheet incl. the capital G10/G11 split for the accountant.
 * Returns the encoded bytes (%PDF...).
 */

/** The footer disclaimer — verbatim per spec §4.5a. Exported so tests assert it survives. */
export const BAS_DISCLAIMER =
  "Prepared by Snapceipt to help you lodge your BAS. These figures are a Simpler BAS summary (G1, 1A, 1B), cash basis, and assume each receipt's GST treatment is correctly classified — confirm the items flagged for review. This is not tax advice and has not been lodged with the ATO. Check against your ATO BAS form before lodging.";

export interface BuildBasPdfInput {
  profileName: string;
  abn: string | null;
  periodLabel: string;
  bas: BasResult;
}

const PAGE_W = 595.28; // A4 portrait points
const PAGE_H = 841.89;
const MARGIN = 48;
const LINE = 16;
const BOTTOM = MARGIN + LINE;

function dollars(cents: number): string {
  return `$${(cents / 100).toFixed(2)}`;
}

export async function buildBasPdf(input: BuildBasPdfInput): Promise<Uint8Array> {
  const doc = await PDFDocument.create();
  const font = await doc.embedFont(StandardFonts.Helvetica);
  const bold = await doc.embedFont(StandardFonts.HelveticaBold);

  let page = doc.addPage([PAGE_W, PAGE_H]);
  let y = PAGE_H - MARGIN;

  const draw = (text: string, f: PDFFont, size: number): void => {
    if (y < BOTTOM) {
      page = doc.addPage([PAGE_W, PAGE_H]);
      y = PAGE_H - MARGIN;
    }
    page.drawText(text, { x: MARGIN, y, size, font: f, color: rgb(0.07, 0.07, 0.07) });
    y -= LINE;
  };

  // Wrap the long disclaimer to the page width (Helvetica ~ size*0.5 avg char width).
  const drawWrapped = (text: string, size: number): void => {
    const maxChars = Math.floor((PAGE_W - 2 * MARGIN) / (size * 0.5));
    const words = text.split(" ");
    let lineBuf = "";
    for (const w of words) {
      if ((lineBuf + " " + w).trim().length > maxChars) {
        draw(lineBuf, font, size);
        lineBuf = w;
      } else {
        lineBuf = (lineBuf + " " + w).trim();
      }
    }
    if (lineBuf) draw(lineBuf, font, size);
  };

  const b = input.bas;

  // Header.
  draw(`Snapceipt BAS — ${input.profileName}`, bold, 18);
  if (input.abn) draw(`ABN: ${input.abn}`, font, 12);
  draw("Registered for GST", font, 12);
  draw(`Period: ${input.periodLabel}`, font, 12);
  draw("Cash basis · Simpler BAS", font, 12);
  y -= LINE / 2;

  // Section 1 — the Simpler BAS spine.
  draw("Lodge these on your BAS", bold, 14);
  draw(`G1  Total sales (incl GST):      ${dollars(b.g1)}`, font, 12);
  draw(`1A  GST on sales:                ${dollars(b.oneA)}`, font, 12);
  draw(`1B  GST on purchases:            ${dollars(b.oneB)}`, font, 12);
  draw(`9   Net GST (1A - 1B):           ${dollars(b.netGstCents)}`, bold, 12);
  draw(`5A  PAYG instalment:             ${dollars(b.paygCents)}`, font, 12);
  draw(`    Total payable/refund:        ${dollars(b.totalPayableCents)}`, bold, 13);
  y -= LINE / 2;

  // Section 2 — working papers (full worksheet, NOT entered on Simpler BAS).
  draw("Working papers (not entered on Simpler BAS)", bold, 14);
  draw(`G2  Exports:                     ${dollars(b.g2)}`, font, 11);
  draw(`G3  Other GST-free sales:        ${dollars(b.g3)}`, font, 11);
  draw(`G4  Input-taxed sales:           ${dollars(b.g4)}`, font, 11);
  draw(`G5  G2+G3+G4:                    ${dollars(b.g5)}`, font, 11);
  draw(`G6  Total sales subject to GST:  ${dollars(b.g6)}`, font, 11);
  draw(`G7  Adjustments:                 ${dollars(b.g7)}`, font, 11);
  draw(`G8  G6+G7:                       ${dollars(b.g8)}`, font, 11);
  draw(`G9  GST on sales (=1A):          ${dollars(b.g9)}`, font, 11);
  draw(`G10 Capital purchases:           ${dollars(b.g10)}`, font, 11);
  draw(`G11 Non-capital purchases:       ${dollars(b.g11)}`, font, 11);
  draw(`G12 G10+G11:                     ${dollars(b.g12)}`, font, 11);
  draw(`G13 Input-taxed purchases:       ${dollars(b.g13)}`, font, 11);
  draw(`G14 GST-free purchases:          ${dollars(b.g14)}`, font, 11);
  draw(`G15 Private-use:                 ${dollars(b.g15)}`, font, 11);
  draw(`G16 G13+G14+G15:                 ${dollars(b.g16)}`, font, 11);
  draw(`G17 Total purchases subj to GST: ${dollars(b.g17)}`, font, 11);
  draw(`G18 Adjustments:                 ${dollars(b.g18)}`, font, 11);
  draw(`G19 G17+G18:                     ${dollars(b.g19)}`, font, 11);
  draw(`G20 GST on purchases (=1B):      ${dollars(b.g20)}`, font, 11);
  y -= LINE / 2;

  // Footer disclaimer (verbatim).
  drawWrapped(BAS_DISCLAIMER, 9);

  return doc.save();
}
