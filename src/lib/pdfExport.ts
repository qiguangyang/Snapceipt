import { PDFDocument, StandardFonts, rgb, type PDFPage, type PDFFont } from "pdf-lib";

/**
 * One-page (paginated if the txn list overflows) summary PDF for /export
 * (spec §4.4). Pure: the route precomputes the totals + top categories. Uses
 * pdf-lib's standard Helvetica (no font file) and no embedded images — pure-JS,
 * Workers-safe. Returns the encoded bytes (%PDF...).
 */

export interface PdfTxnRow {
  txn_date: string;
  merchant: string;
  cat_key: string;
  amount_cents: number;
  gst_cents: number | null;
  deductible_pct: number | null;
}

export interface BuildPdfInput {
  profileName: string;
  periodLabel: string;
  deductibleTotalCents: number;
  gstTotalCents: number;
  topCategories: { catKey: string; spendCents: number }[];
  rows: PdfTxnRow[];
}

const PAGE_W = 595.28; // A4 portrait points
const PAGE_H = 841.89;
const MARGIN = 48;
const LINE = 16;
const BOTTOM = MARGIN + LINE;

function dollars(cents: number): string {
  return `$${(cents / 100).toFixed(2)}`;
}

export async function buildExportPdf(input: BuildPdfInput): Promise<Uint8Array> {
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

  // Header.
  draw(`Snapceipt — ${input.profileName}`, bold, 18);
  draw(`Period: ${input.periodLabel}`, font, 12);
  y -= LINE / 2;

  // Totals.
  draw(`Deductible total: ${dollars(input.deductibleTotalCents)}`, bold, 13);
  draw(`GST on purchases: ${dollars(input.gstTotalCents)}`, bold, 13);
  y -= LINE / 2;

  // Top-5 categories.
  draw("Top categories", bold, 13);
  if (input.topCategories.length === 0) {
    draw("  (no expenses in this period)", font, 11);
  } else {
    for (const c of input.topCategories.slice(0, 5)) {
      draw(`  ${c.catKey}: ${dollars(c.spendCents)}`, font, 11);
    }
  }
  y -= LINE / 2;

  // Transaction list.
  draw("Transactions", bold, 13);
  draw("date        merchant        amount    gst     deductible%", font, 10);
  for (const r of input.rows) {
    const ded = r.deductible_pct == null ? "-" : `${r.deductible_pct}%`;
    const gst = r.gst_cents == null ? "-" : dollars(r.gst_cents);
    const merchant = r.merchant.length > 22 ? `${r.merchant.slice(0, 21)}…` : r.merchant;
    draw(`${r.txn_date}  ${merchant.padEnd(22)} ${dollars(r.amount_cents).padStart(9)}  ${gst.padStart(7)}  ${ded}`, font, 10);
  }

  return doc.save();
}
