import { Hono } from "hono";
import type { AppEnv } from "../env";
import { ApiError } from "../lib/errors";
import { nowMs } from "../lib/time";
import { uuidv7 } from "../lib/ids";
import { recomputeTotals, type QuoteLineItemAmounts } from "../lib/quoteTotals";
import { assignQuoteNumber } from "../lib/quoteCounter";
import { buildQuotePdf, type QuoteLineItemRow, type QuoteSender } from "../lib/pdfQuote";
import * as emailModule from "../lib/email";
import { signDownloadToken, verifyDownloadToken, DOWNLOAD_TTL_SECONDS } from "../lib/exportToken";

/**
 * POST /quotes/:id/send        — Bearer (global auth) + rate tier "quotes" (app.ts).
 * GET  /quotes/dl/:token       — PUBLIC (in PUBLIC_PATHS); streams the signed R2 PDF.
 *
 * The ONLY new quote routes — quote/line-item/client CRUD stays on /sync.
 */
export const quotesRoutes = new Hono<AppEnv>();

interface QuoteRow {
  id: string;
  user_id: string;
  profile_id: string;
  number: string | null;
  client_name: string | null;
  client_email: string | null;
  gst_enabled: number;
  gst_inclusive: number;
  valid_until: string | null;
}

interface LineItemRow {
  description: string;
  quantity: number;
  unit_price_cents: number;
}

/** UTC YYYY-MM-DD for an epoch-ms instant. */
function utcDate(ms: number): string {
  return new Date(ms).toISOString().slice(0, 10);
}

quotesRoutes.post("/:id/pdf", async (c) => {
  const userId = c.var.userId;
  const quoteId = c.req.param("id");

  // 1. Load the quote (scoped to the authed user).
  const quote = await c.env.DB.prepare(
    `SELECT id, user_id, profile_id, number, client_name, client_email, gst_enabled, gst_inclusive, valid_until
       FROM quotes WHERE id = ? AND user_id = ? AND deleted_at IS NULL`,
  ).bind(quoteId, userId).first<QuoteRow>();
  if (!quote) throw new ApiError("NOT_FOUND", "Quote not found for this user");

  // 2. Load its non-deleted line items (deterministic order).
  const { results: lineItems } = await c.env.DB.prepare(
    `SELECT description, quantity, unit_price_cents
       FROM quote_line_items
      WHERE quote_id = ? AND user_id = ? AND deleted_at IS NULL
      ORDER BY sort_order ASC, id ASC`,
  ).bind(quoteId, userId).all<LineItemRow>();
  if (lineItems.length === 0) {
    throw new ApiError("VALIDATION_FAILED", "Cannot build a PDF for a quote with no line items");
  }

  // 3. Recompute totals authoritatively.
  const gstEnabled = quote.gst_enabled === 1;
  const gstInclusive = quote.gst_inclusive === 1;
  const totals = recomputeTotals(
    lineItems.map((li): QuoteLineItemAmounts => ({ quantity: li.quantity, unitPriceCents: li.unit_price_cents })),
    gstEnabled,
    gstInclusive,
  );

  // 4. Mint SN-#### only if the quote has none yet (so the PDF shows a real number).
  //    A re-build keeps the existing number — generating a PDF never changes status (§2.1).
  const number = quote.number ?? (await assignQuoteNumber(c.env.DB, userId));

  // 5. Load the owning profile for the PDF sender block.
  const profile = await c.env.DB.prepare(
    `SELECT name, abn, gst_registered FROM profiles WHERE id = ? AND user_id = ? AND deleted_at IS NULL`,
  ).bind(quote.profile_id, userId).first<{ name: string; abn: string | null; gst_registered: number | null }>();
  if (!profile) throw new ApiError("NOT_FOUND", "Profile not found for this quote");
  const sender: QuoteSender = {
    name: profile.name,
    abn: profile.abn,
    gstRegistered: profile.gst_registered === 1,
  };

  // 6. Build the PDF -> R2 (same key as the send path; a re-build overwrites it).
  const now = nowMs();
  const pdf = await buildQuotePdf(
    {
      number,
      clientName: quote.client_name,
      clientEmail: quote.client_email,
      gstEnabled,
      gstInclusive,
      subtotalCents: totals.subtotalCents,
      gstCents: totals.gstCents,
      totalCents: totals.totalCents,
      validUntil: quote.valid_until,
      issuedDate: utcDate(now),
    },
    lineItems.map((li): QuoteLineItemRow => ({
      description: li.description,
      quantity: li.quantity,
      unitPriceCents: li.unit_price_cents,
    })),
    sender,
  );
  const key = `${userId}/quotes/${quoteId}.pdf`;
  await c.env.RECEIPTS.put(key, pdf, { httpMetadata: { contentType: "application/pdf" } });

  // 7. Persist number + totals + pdf_r2_key. NO status change, NO sent_at (§2.1).
  await c.env.DB.prepare(
    `UPDATE quotes
        SET number = ?, pdf_r2_key = ?,
            subtotal_cents = ?, gst_cents = ?, total_cents = ?,
            updated_at = ?
      WHERE id = ? AND user_id = ?`,
  ).bind(number, key, totals.subtotalCents, totals.gstCents, totals.totalCents, now, quoteId, userId).run();

  // 8. Signed 7-day download link.
  const origin = new URL(c.req.url).origin;
  const token = await signDownloadToken(c.env.JWT_SIGNING_KEY, key);
  const pdfUrl = `${origin}/quotes/dl/${token}`;
  const expiresAt = now + DOWNLOAD_TTL_SECONDS * 1000;

  // 9. Response — status stays draft (no email, no outbox).
  return c.json({
    number,
    status: "draft",
    subtotalCents: totals.subtotalCents,
    gstCents: totals.gstCents,
    totalCents: totals.totalCents,
    pdfUrl,
    expiresAt,
  });
});

quotesRoutes.post("/:id/send", async (c) => {
  const userId = c.var.userId;
  const quoteId = c.req.param("id");

  // 1. Load the quote (scoped to the authed user).
  const quote = await c.env.DB.prepare(
    `SELECT id, user_id, profile_id, number, client_name, client_email, gst_enabled, gst_inclusive, valid_until
       FROM quotes WHERE id = ? AND user_id = ? AND deleted_at IS NULL`,
  ).bind(quoteId, userId).first<QuoteRow>();
  if (!quote) throw new ApiError("NOT_FOUND", "Quote not found for this user");

  // 2. Load its non-deleted line items (deterministic order).
  const { results: lineItems } = await c.env.DB.prepare(
    `SELECT description, quantity, unit_price_cents
       FROM quote_line_items
      WHERE quote_id = ? AND user_id = ? AND deleted_at IS NULL
      ORDER BY sort_order ASC, id ASC`,
  ).bind(quoteId, userId).all<LineItemRow>();
  if (lineItems.length === 0) {
    throw new ApiError("VALIDATION_FAILED", "Cannot send a quote with no line items");
  }

  // 2b. Email PRECONDITION — validate BEFORE any mutation. A quote send always
  // attempts to email the client (the F2 accountant export proves the production
  // pattern: call the email seam unconditionally + try/catch), so a missing client
  // email is a hard 400 that must NOT burn a number / flip status / write R2 / log
  // an outbox row. This ordering honours spec §8: on a validation failure no number
  // is consumed and the quote stays draft.
  // (NOTE: the `send_email` binding declares `allowed_sender_addresses`, which the
  // vitest-pool-workers / miniflare runtime does NOT materialize, so `c.env.EMAIL`
  // is undefined under test — gating the send on `Boolean(c.env.EMAIL)` would make
  // the whole send path dead there. The send seam (`sendQuoteEmail`) already isolates
  // the actual `env.EMAIL.send` and is spied in tests, exactly like `sendExportEmail`.)
  if (!quote.client_email) {
    throw new ApiError("VALIDATION_FAILED", "Quote has no client email to send to");
  }

  // 3. Recompute totals authoritatively.
  const gstEnabled = quote.gst_enabled === 1;
  const gstInclusive = quote.gst_inclusive === 1;
  const totals = recomputeTotals(
    lineItems.map((li): QuoteLineItemAmounts => ({ quantity: li.quantity, unitPriceCents: li.unit_price_cents })),
    gstEnabled,
    gstInclusive,
  );

  // 4. Mint SN-#### only on the first send; a re-send keeps the existing number.
  const number = quote.number ?? (await assignQuoteNumber(c.env.DB, userId));

  // 5. Load the owning profile for the PDF sender block.
  const profile = await c.env.DB.prepare(
    `SELECT name, abn, gst_registered FROM profiles WHERE id = ? AND user_id = ? AND deleted_at IS NULL`,
  ).bind(quote.profile_id, userId).first<{ name: string; abn: string | null; gst_registered: number | null }>();
  if (!profile) throw new ApiError("NOT_FOUND", "Profile not found for this quote");
  const sender: QuoteSender = {
    name: profile.name,
    abn: profile.abn,
    gstRegistered: profile.gst_registered === 1,
  };

  // 6. Build the PDF -> R2.
  const now = nowMs();
  const pdf = await buildQuotePdf(
    {
      number,
      clientName: quote.client_name,
      clientEmail: quote.client_email,
      gstEnabled,
      gstInclusive,
      subtotalCents: totals.subtotalCents,
      gstCents: totals.gstCents,
      totalCents: totals.totalCents,
      validUntil: quote.valid_until,
      issuedDate: utcDate(now),
    },
    lineItems.map((li): QuoteLineItemRow => ({
      description: li.description,
      quantity: li.quantity,
      unitPriceCents: li.unit_price_cents,
    })),
    sender,
  );
  const key = `${userId}/quotes/${quoteId}.pdf`;
  await c.env.RECEIPTS.put(key, pdf, { httpMetadata: { contentType: "application/pdf" } });

  // 7. Persist totals + number + status=sent + sent_at.
  await c.env.DB.prepare(
    `UPDATE quotes
        SET number = ?, status = 'sent', sent_at = ?,
            subtotal_cents = ?, gst_cents = ?, total_cents = ?,
            updated_at = ?
      WHERE id = ? AND user_id = ?`,
  ).bind(number, now, totals.subtotalCents, totals.gstCents, totals.totalCents, now, quoteId, userId).run();

  // 8. Signed 7-day download link.
  const origin = new URL(c.req.url).origin;
  const token = await signDownloadToken(c.env.JWT_SIGNING_KEY, key);
  const pdfUrl = `${origin}/quotes/dl/${token}`;
  const expiresAt = now + DOWNLOAD_TTL_SECONDS * 1000;

  // 9. email_outbox row + gated send.
  const outboxId = uuidv7();
  await c.env.DB.prepare(
    `INSERT INTO email_outbox (id, user_id, to_email, kind, subject, status, export_format, export_r2_key, related_id, created_at)
     VALUES (?, ?, ?, 'quote_send', ?, 'queued', 'pdf', ?, ?, ?)`,
  ).bind(outboxId, userId, quote.client_email ?? "", `Quote ${number}`, key, quoteId, now).run();

  // Attempt the send exactly like the F2 accountant export: call the `sendQuoteEmail`
  // seam (which wraps `env.EMAIL.send`) unconditionally inside a try/catch, then flip
  // the outbox row sent/failed. A failure (incl. a missing/un-materialized EMAIL
  // binding surfacing as a thrown error) leaves the outbox `failed`, `emailed:false`,
  // and the route still 200s — the number is already minted and the status is `sent`.
  // The missing-client-email case is already rejected as a 400 in step 2b BEFORE any
  // mutation, so here quote.client_email is guaranteed non-null.
  let emailed = false;
  const trader = await c.env.DB.prepare(`SELECT email FROM users WHERE id = ?`)
    .bind(userId).first<{ email: string | null }>();
  try {
    await emailModule.sendQuoteEmail(c.env, {
      to: quote.client_email,
      replyTo: trader?.email ?? "noreply@snapceipt.cc",
      quoteNumber: number,
      clientName: quote.client_name,
      totalCents: totals.totalCents,
      pdf,
    });
    await c.env.DB.prepare(`UPDATE email_outbox SET status='sent', sent_at=? WHERE id=?`)
      .bind(nowMs(), outboxId).run();
    emailed = true;
  } catch (err) {
    await c.env.DB.prepare(`UPDATE email_outbox SET status='failed', error=? WHERE id=?`)
      .bind(String(err instanceof Error ? err.message : err), outboxId).run();
    emailed = false;
  }

  // 10. Response.
  return c.json({
    number,
    sentAt: now,
    status: "sent",
    subtotalCents: totals.subtotalCents,
    gstCents: totals.gstCents,
    totalCents: totals.totalCents,
    pdfUrl,
    expiresAt,
    emailed,
  });
});

// PUBLIC: GET /quotes/dl/:token — verify the signed token + stream the R2 PDF.
quotesRoutes.get("/dl/:token", async (c) => {
  const token = c.req.param("token");
  let r2Key: string;
  try {
    ({ r2Key } = await verifyDownloadToken(c.env.JWT_SIGNING_KEY, token));
  } catch {
    throw new ApiError("FORBIDDEN", "Invalid or expired download link");
  }
  const obj = await c.env.RECEIPTS.get(r2Key);
  if (!obj) throw new ApiError("NOT_FOUND", "Quote PDF not found");

  // Buffer fully (mirrors export.ts) so the R2 read completes before the response
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
