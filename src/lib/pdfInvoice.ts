import { PDFDocument, StandardFonts, rgb, type PDFPage, type PDFFont } from "pdf-lib";

/**
 * Tax-invoice PDF (spec §4.3) — clones src/lib/pdfQuote.ts: A4 portrait, pdf-lib
 * StandardFonts (no font file), no embedded images (pure-JS, Workers-safe). Pure:
 * the route recomputes the totals (recomputeTotals) and passes them in along with
 * the derived amountPaidCents. Returns the encoded bytes (%PDF...).
 */

/** The seller block — drawn from the active Business Profile. */
export interface InvoiceSender {
  name: string;
  abn: string | null;
  gstRegistered: boolean;
}

/** One line-item row as rendered in the body table. */
export interface InvoiceLineItemRow {
  description: string;
  quantity: number;
  unitPriceCents: number;
}

/** The invoice header/meta/totals the PDF needs (totals already recomputed). */
export interface InvoicePdfData {
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
  /** YYYY-MM-DD issue date (the route passes the issued UTC date). */
  issueDate: string;
  dueDate: string | null;
  /** Σ non-deleted Payment.amountCents; when > 0 the paid/balance ledger renders. */
  amountPaidCents: number;
}

/** Compliance-critical literals — exported so tests can assert verbatim wording. */
export const INVOICE_HEADING = "Tax invoice";
export const GST_REGISTERED_LABEL = "Registered for GST";
export const GST_INCLUSIVE_NOTE = "Total price includes GST";

const PAGE_W = 595.28; // A4 portrait points
const PAGE_H = 841.89;
const MARGIN = 48;
const LINE = 16;
const BOTTOM = MARGIN + LINE;

function dollars(cents: number): string {
  return `$${(cents / 100).toFixed(2)}`;
}

export async function buildInvoicePdf(
  invoice: InvoicePdfData,
  lineItems: InvoiceLineItemRow[],
  sender: InvoiceSender,
): Promise<Uint8Array> {
  const doc = await PDFDocument.create();
  const font = await doc.embedFont(StandardFonts.Helvetica);
  const bold = await doc.embedFont(StandardFonts.HelveticaBold);

  let page: PDFPage = doc.addPage([PAGE_W, PAGE_H]);
  let y = PAGE_H - MARGIN;

  const draw = (text: string, f: PDFFont, size: number): void => {
    if (y < BOTTOM) {
      page = doc.addPage([PAGE_W, PAGE_H]);
      y = PAGE_H - MARGIN;
    }
    page.drawText(text, { x: MARGIN, y, size, font: f, color: rgb(0.07, 0.07, 0.07) });
    y -= LINE;
  };

  // Heading — ATO "Tax invoice".
  draw(INVOICE_HEADING, bold, 18);
  y -= LINE / 2;

  // Seller (Business profile) — name + ABN + GST registration line.
  draw(sender.name, bold, 14);
  if (sender.abn) draw(`ABN: ${sender.abn}`, font, 11);
  if (sender.gstRegistered) draw(GST_REGISTERED_LABEL, font, 11);
  y -= LINE / 2;

  // Meta — number + issue/due dates.
  draw(`Invoice ${invoice.number ?? "(draft)"}`, bold, 14);
  draw(`Issue date: ${invoice.issueDate}`, font, 11);
  if (invoice.dueDate) draw(`Due date: ${invoice.dueDate}`, font, 11);
  y -= LINE / 2;

  // Bill-to.
  draw("Bill to", bold, 12);
  draw(invoice.clientName ?? "(no client)", font, 11);
  if (invoice.clientEmail) draw(invoice.clientEmail, font, 11);
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

  // Totals. Inclusive mode relabels the ledger exactly as the quote PDF does: the
  // subtotal is the ex-GST base and the GST line is the embedded portion (the total
  // equals the entered, GST-inclusive sum). Amounts are already recomputed for the mode.
  const inclusive = invoice.gstEnabled && invoice.gstInclusive;
  draw(`${inclusive ? "Subtotal (ex GST)" : "Subtotal"}: ${dollars(invoice.subtotalCents)}`, font, 12);
  if (invoice.gstEnabled) {
    draw(`GST (10%)${inclusive ? " included" : ""}: ${dollars(invoice.gstCents)}`, font, 12);
  }
  draw(`Total: ${dollars(invoice.totalCents)}`, bold, 14);
  if (inclusive) draw(`${GST_INCLUSIVE_NOTE} ${dollars(invoice.gstCents)}.`, font, 9);

  // Accounts-receivable ledger — only when something has been paid.
  if (invoice.amountPaidCents > 0) {
    y -= LINE / 2;
    draw(`Amount paid: ${dollars(invoice.amountPaidCents)}`, font, 12);
    draw(`Balance due: ${dollars(invoice.totalCents - invoice.amountPaidCents)}`, bold, 13);
  }
  y -= LINE / 2;

  // Footer.
  draw("Please remit payment by the due date. Thank you.", font, 9);

  return doc.save();
}
