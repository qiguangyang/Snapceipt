import { Hono, type Context } from "hono";
import type { AppEnv } from "../env";
import { ApiError } from "../lib/errors";
import { nowMs } from "../lib/time";
import { recomputeTotals, type QuoteLineItemAmounts } from "../lib/quoteTotals";
import { assignInvoiceNumber } from "../lib/invoiceCounter";
import { buildInvoicePdf, type InvoiceLineItemRow, type InvoiceSender } from "../lib/pdfInvoice";
import { amountPaidCents } from "../lib/invoiceTotals";
import { signDownloadToken, verifyDownloadToken, DOWNLOAD_TTL_SECONDS } from "../lib/exportToken";
import * as emailModule from "../lib/email";
import { uuidv7 } from "../lib/ids";

/**
 * POST /invoices/:id/issue  — Bearer (global auth) + rate tier "quotes" (app.ts).
 * GET  /invoices/dl/:token  — PUBLIC (in PUBLIC_PATHS); streams the signed R2 PDF.
 *
 * Invoice/line-item/payment CRUD stays on /sync; only issue/send/pdf/dl live here.
 * (POST /invoices/:id/send and POST /invoices/:id/pdf are appended onto this router.)
 */
export const invoicesRoutes = new Hono<AppEnv>();

interface InvoiceRow {
  id: string;
  user_id: string;
  profile_id: string;
  number: string | null;
  client_name: string | null;
  client_email: string | null;
  gst_enabled: number;
  gst_inclusive: number;
  status: string;
  issue_date: string | null;
  due_date: string | null;
  issued_at: number | null;
  pdf_r2_key: string | null;
}

interface InvoiceLineRow {
  description: string;
  quantity: number;
  unit_price_cents: number;
}

/** UTC YYYY-MM-DD for an epoch-ms instant. */
function utcDate(ms: number): string {
  return new Date(ms).toISOString().slice(0, 10);
}

/** Shared loader: invoice + its non-deleted line items + the owning profile/sender. */
async function loadInvoiceForPdf(
  c: Context<AppEnv>,
  invoiceId: string,
  userId: string,
): Promise<{
  invoice: InvoiceRow;
  lineItems: InvoiceLineRow[];
  sender: InvoiceSender;
}> {
  const invoice = await c.env.DB.prepare(
    `SELECT id, user_id, profile_id, number, client_name, client_email, gst_enabled, gst_inclusive,
            status, issue_date, due_date, issued_at, pdf_r2_key
       FROM invoices WHERE id = ? AND user_id = ? AND deleted_at IS NULL`,
  ).bind(invoiceId, userId).first<InvoiceRow>();
  if (!invoice) throw new ApiError("NOT_FOUND", "Invoice not found for this user");

  const { results: lineItems } = await c.env.DB.prepare(
    `SELECT description, quantity, unit_price_cents
       FROM invoice_line_items
      WHERE invoice_id = ? AND user_id = ? AND deleted_at IS NULL
      ORDER BY sort_order ASC, id ASC`,
  ).bind(invoiceId, userId).all<InvoiceLineRow>();
  if (lineItems.length === 0) {
    throw new ApiError("VALIDATION_FAILED", "Cannot build a PDF for an invoice with no line items");
  }

  const profile = await c.env.DB.prepare(
    `SELECT name, abn, gst_registered FROM profiles WHERE id = ? AND user_id = ? AND deleted_at IS NULL`,
  ).bind(invoice.profile_id, userId).first<{ name: string; abn: string | null; gst_registered: number | null }>();
  if (!profile) throw new ApiError("NOT_FOUND", "Profile not found for this invoice");

  return {
    invoice,
    lineItems,
    sender: { name: profile.name, abn: profile.abn, gstRegistered: profile.gst_registered === 1 },
  };
}

/** Σ non-deleted payment amounts for the invoice (derived, never stored). */
async function invoiceAmountPaidCents(
  db: D1Database,
  invoiceId: string,
  userId: string,
): Promise<number> {
  const { results } = await db.prepare(
    `SELECT amount_cents FROM payments WHERE invoice_id = ? AND user_id = ? AND deleted_at IS NULL`,
  ).bind(invoiceId, userId).all<{ amount_cents: number }>();
  return amountPaidCents(results.map((p) => ({ amountCents: p.amount_cents })));
}

invoicesRoutes.post("/:id/issue", async (c) => {
  const userId = c.var.userId;
  const invoiceId = c.req.param("id");

  const { invoice, lineItems, sender } = await loadInvoiceForPdf(c, invoiceId, userId);

  // Recompute totals authoritatively.
  const gstEnabled = invoice.gst_enabled === 1;
  const gstInclusive = invoice.gst_inclusive === 1;
  const totals = recomputeTotals(
    lineItems.map((li): QuoteLineItemAmounts => ({ quantity: li.quantity, unitPriceCents: li.unit_price_cents })),
    gstEnabled,
    gstInclusive,
  );

  // Mint INV-#### per PROFILE only on the FIRST issue; a re-issue keeps the number,
  // issue_date, and issued_at (idempotent). status flips to issued either way.
  const now = nowMs();
  const number = invoice.number ?? (await assignInvoiceNumber(c.env.DB, invoice.profile_id));
  const issueDate = invoice.issue_date ?? utcDate(now);
  const issuedAt = invoice.issued_at ?? now;

  // Build the tax-invoice PDF (incl. the derived amount-paid ledger) -> R2.
  const paidCents = await invoiceAmountPaidCents(c.env.DB, invoiceId, userId);
  const pdf = await buildInvoicePdf(
    {
      number,
      clientName: invoice.client_name,
      clientEmail: invoice.client_email,
      gstEnabled,
      gstInclusive,
      subtotalCents: totals.subtotalCents,
      gstCents: totals.gstCents,
      totalCents: totals.totalCents,
      issueDate,
      dueDate: invoice.due_date,
      amountPaidCents: paidCents,
    },
    lineItems.map((li): InvoiceLineItemRow => ({
      description: li.description,
      quantity: li.quantity,
      unitPriceCents: li.unit_price_cents,
    })),
    sender,
  );
  const key = `${userId}/invoices/${invoiceId}.pdf`;
  await c.env.RECEIPTS.put(key, pdf, { httpMetadata: { contentType: "application/pdf" } });

  // Persist: number, status=issued, dates, totals, pdf_r2_key.
  await c.env.DB.prepare(
    `UPDATE invoices
        SET number = ?, status = 'issued', issue_date = ?, issued_at = ?, pdf_r2_key = ?,
            subtotal_cents = ?, gst_cents = ?, total_cents = ?, updated_at = ?
      WHERE id = ? AND user_id = ?`,
  ).bind(number, issueDate, issuedAt, key, totals.subtotalCents, totals.gstCents, totals.totalCents, now, invoiceId, userId).run();

  const origin = new URL(c.req.url).origin;
  const token = await signDownloadToken(c.env.JWT_SIGNING_KEY, key);
  const pdfUrl = `${origin}/invoices/dl/${token}`;
  const expiresAt = now + DOWNLOAD_TTL_SECONDS * 1000;

  return c.json({
    number,
    status: "issued",
    issueDate,
    issuedAt,
    subtotalCents: totals.subtotalCents,
    gstCents: totals.gstCents,
    totalCents: totals.totalCents,
    pdfUrl,
    expiresAt,
  });
});

/** (Re)build the invoice PDF -> R2 + persist pdf_r2_key + recomputed totals.
 *  Returns the recomputed total + the R2 key + the (unchanged) invoice status.
 *  NO number mint, NO status change — both /send and /pdf reuse this. */
async function rebuildInvoicePdf(
  c: Context<AppEnv>,
  invoiceId: string,
  userId: string,
): Promise<{
  key: string;
  totalCents: number;
  status: string;
  pdf: Uint8Array;
  clientName: string | null;
  clientEmail: string | null;
  number: string | null;
}> {
  const { invoice, lineItems, sender } = await loadInvoiceForPdf(c, invoiceId, userId);
  const gstEnabled = invoice.gst_enabled === 1;
  const gstInclusive = invoice.gst_inclusive === 1;
  const totals = recomputeTotals(
    lineItems.map((li): QuoteLineItemAmounts => ({ quantity: li.quantity, unitPriceCents: li.unit_price_cents })),
    gstEnabled,
    gstInclusive,
  );
  const now = nowMs();
  const paidCents = await invoiceAmountPaidCents(c.env.DB, invoiceId, userId);
  const pdf = await buildInvoicePdf(
    {
      number: invoice.number,
      clientName: invoice.client_name,
      clientEmail: invoice.client_email,
      gstEnabled,
      gstInclusive,
      subtotalCents: totals.subtotalCents,
      gstCents: totals.gstCents,
      totalCents: totals.totalCents,
      issueDate: invoice.issue_date ?? utcDate(now),
      dueDate: invoice.due_date,
      amountPaidCents: paidCents,
    },
    lineItems.map((li): InvoiceLineItemRow => ({
      description: li.description,
      quantity: li.quantity,
      unitPriceCents: li.unit_price_cents,
    })),
    sender,
  );
  const key = `${userId}/invoices/${invoiceId}.pdf`;
  await c.env.RECEIPTS.put(key, pdf, { httpMetadata: { contentType: "application/pdf" } });
  await c.env.DB.prepare(
    `UPDATE invoices
        SET pdf_r2_key = ?, subtotal_cents = ?, gst_cents = ?, total_cents = ?, updated_at = ?
      WHERE id = ? AND user_id = ?`,
  ).bind(key, totals.subtotalCents, totals.gstCents, totals.totalCents, now, invoiceId, userId).run();
  return {
    key,
    totalCents: totals.totalCents,
    status: invoice.status,
    pdf,
    clientName: invoice.client_name,
    clientEmail: invoice.client_email,
    number: invoice.number,
  };
}

invoicesRoutes.post("/:id/send", async (c) => {
  const userId = c.var.userId;
  const invoiceId = c.req.param("id");

  // Email PRECONDITION — validate BEFORE any mutation (mirrors the quote send): the
  // invoice must have a client email. loadInvoiceForPdf also 400s on no line items
  // and 404s on unknown/other-user, all before R2/outbox writes.
  const { invoice } = await loadInvoiceForPdf(c, invoiceId, userId);
  if (!invoice.client_email) {
    throw new ApiError("VALIDATION_FAILED", "Invoice has no client email to send to");
  }

  // Ensure a current PDF -> R2 + persist key/totals (no status change, no number mint).
  const built = await rebuildInvoicePdf(c, invoiceId, userId);

  const origin = new URL(c.req.url).origin;
  const token = await signDownloadToken(c.env.JWT_SIGNING_KEY, built.key);
  const pdfUrl = `${origin}/invoices/dl/${token}`;
  const now = nowMs();
  const expiresAt = now + DOWNLOAD_TTL_SECONDS * 1000;

  // email_outbox row + gated send (mirrors the quote send exactly).
  const outboxId = uuidv7();
  await c.env.DB.prepare(
    `INSERT INTO email_outbox (id, user_id, to_email, kind, subject, status, export_format, export_r2_key, related_id, created_at)
     VALUES (?, ?, ?, 'invoice_send', ?, 'queued', 'pdf', ?, ?, ?)`,
  ).bind(outboxId, userId, built.clientEmail ?? "", `Invoice ${built.number ?? ""}`, built.key, invoiceId, now).run();

  let emailed = false;
  const trader = await c.env.DB.prepare(`SELECT email FROM users WHERE id = ?`)
    .bind(userId).first<{ email: string | null }>();
  try {
    await emailModule.sendInvoiceEmail(c.env, {
      to: built.clientEmail!,
      replyTo: trader?.email ?? "noreply@snapceipt.cc",
      invoiceNumber: built.number ?? "",
      clientName: built.clientName,
      totalCents: built.totalCents,
      pdf: built.pdf,
    });
    await c.env.DB.prepare(`UPDATE email_outbox SET status='sent', sent_at=? WHERE id=?`)
      .bind(nowMs(), outboxId).run();
    emailed = true;
  } catch (err) {
    await c.env.DB.prepare(`UPDATE email_outbox SET status='failed', error=? WHERE id=?`)
      .bind(String(err instanceof Error ? err.message : err), outboxId).run();
    emailed = false;
  }

  return c.json({ status: built.status, totalCents: built.totalCents, pdfUrl, expiresAt, emailed });
});

invoicesRoutes.post("/:id/pdf", async (c) => {
  const userId = c.var.userId;
  const invoiceId = c.req.param("id");
  const built = await rebuildInvoicePdf(c, invoiceId, userId);

  const origin = new URL(c.req.url).origin;
  const token = await signDownloadToken(c.env.JWT_SIGNING_KEY, built.key);
  const pdfUrl = `${origin}/invoices/dl/${token}`;
  const expiresAt = nowMs() + DOWNLOAD_TTL_SECONDS * 1000;

  return c.json({ status: built.status, totalCents: built.totalCents, pdfUrl, expiresAt });
});

// PUBLIC: GET /invoices/dl/:token — verify the signed token + stream the R2 PDF.
invoicesRoutes.get("/dl/:token", async (c) => {
  const token = c.req.param("token");
  let r2Key: string;
  try {
    ({ r2Key } = await verifyDownloadToken(c.env.JWT_SIGNING_KEY, token));
  } catch {
    throw new ApiError("FORBIDDEN", "Invalid or expired download link");
  }
  const obj = await c.env.RECEIPTS.get(r2Key);
  if (!obj) throw new ApiError("NOT_FOUND", "Invoice PDF not found");

  // Buffer fully (mirrors quotes/dl) so the R2 read completes before the response
  // returns — a dangling stream blocks vitest-pool-workers teardown.
  const bytes = await obj.arrayBuffer();
  const contentType = obj.httpMetadata?.contentType ?? "application/octet-stream";
  const filename = r2Key.slice(r2Key.lastIndexOf("/") + 1);
  return new Response(bytes, {
    status: 200,
    headers: {
      "content-type": contentType,
      "content-disposition": `attachment; filename="${filename}"`,
    },
  });
});
