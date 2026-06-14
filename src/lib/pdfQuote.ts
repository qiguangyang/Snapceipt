import { PDFDocument, StandardFonts, rgb, type PDFPage, type PDFFont } from "pdf-lib";

/**
 * Quote PDF (spec §4.4) — clones src/lib/pdfExport.ts: A4 portrait, pdf-lib
 * StandardFonts (no font file), no embedded images (pure-JS, Workers-safe).
 * Pure: the route recomputes the totals (recomputeTotals) and passes them in.
 * Returns the encoded bytes (%PDF...).
 */

/** The sender block — drawn from the active Business Profile. */
export interface QuoteSender {
  name: string;
  abn: string | null;
  gstRegistered: boolean;
}

/** One line-item row as rendered in the body table. */
export interface QuoteLineItemRow {
  description: string;
  quantity: number;
  unitPriceCents: number;
}

/** The quote header/meta/totals the PDF needs (totals already recomputed). */
export interface QuotePdfData {
  number: string | null;
  clientName: string | null;
  clientEmail: string | null;
  gstEnabled: boolean;
  /** When true (and gstEnabled), prices include GST: subtotal is ex-GST, GST is the
   *  embedded portion, and the total equals the entered sum. */
  gstInclusive: boolean;
  subtotalCents: number;
  gstCents: number;
  totalCents: number;
  validUntil: string | null;
  /** YYYY-MM-DD issued date (the route passes today's UTC date). */
  issuedDate: string;
}

const PAGE_W = 595.28; // A4 portrait points
const PAGE_H = 841.89;
const MARGIN = 48;
const LINE = 16;
const BOTTOM = MARGIN + LINE;

function dollars(cents: number): string {
  return `$${(cents / 100).toFixed(2)}`;
}

export async function buildQuotePdf(
  quote: QuotePdfData,
  lineItems: QuoteLineItemRow[],
  sender: QuoteSender,
): Promise<Uint8Array> {
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

  // Header — the sender (Business profile).
  draw(sender.name, bold, 18);
  if (sender.abn) draw(`ABN: ${sender.abn}`, font, 11);
  if (sender.gstRegistered) draw("Registered for GST", font, 11);
  y -= LINE / 2;

  // Meta.
  draw(`Quote ${quote.number ?? "(draft)"}`, bold, 14);
  draw(`Issued: ${quote.issuedDate}`, font, 11);
  if (quote.validUntil) draw(`Valid until ${quote.validUntil}`, font, 11);
  y -= LINE / 2;

  // Bill-to.
  draw("Bill to", bold, 12);
  draw(quote.clientName ?? "(no client)", font, 11);
  if (quote.clientEmail) draw(quote.clientEmail, font, 11);
  y -= LINE / 2;

  // Line-items table.
  draw("Items", bold, 12);
  draw("description            qty   unit        amount", font, 10);
  for (const li of lineItems) {
    const desc = li.description.length > 22 ? `${li.description.slice(0, 21)}…` : li.description;
    const amount = li.quantity * li.unitPriceCents;
    draw(
      `${desc.padEnd(22)} ${String(li.quantity).padStart(4)}  ${dollars(li.unitPriceCents).padStart(9)}  ${dollars(amount).padStart(9)}`,
      font,
      10,
    );
  }
  y -= LINE / 2;

  // Totals. Inclusive mode relabels the ledger: the subtotal is the ex-GST base and
  // the GST line is the embedded portion (the total equals the entered, GST-inclusive
  // sum). The subtotal/gst/total amounts are already recomputed for the mode.
  const inclusive = quote.gstEnabled && quote.gstInclusive;
  draw(`${inclusive ? "Subtotal (ex GST)" : "Subtotal"}: ${dollars(quote.subtotalCents)}`, font, 12);
  if (quote.gstEnabled) {
    draw(`GST (10%)${inclusive ? " included" : ""}: ${dollars(quote.gstCents)}`, font, 12);
  }
  draw(`Total: ${dollars(quote.totalCents)}`, bold, 14);
  if (inclusive) draw("Prices include GST.", font, 9);
  y -= LINE / 2;

  // Footer.
  draw("Valid for 14 days. Accepted quotes convert to an invoice.", font, 9);

  return doc.save();
}
