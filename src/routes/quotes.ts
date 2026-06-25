import { Hono } from "hono";
import type { AppEnv, Env } from "../env";
import { ApiError } from "../lib/errors";
import { nowMs } from "../lib/time";
import { uuidv7 } from "../lib/ids";
import { recomputeTotals, type QuoteLineItemAmounts } from "../lib/quoteTotals";
import { assignQuoteNumber } from "../lib/quoteCounter";
import * as emailModule from "../lib/email";
import { signQuoteLinkToken } from "../lib/exportToken";
import { type QuoteHtmlData } from "../lib/quoteHtml";

/**
 * POST /quotes/:id/link  — Bearer; mint a 30-day signed link to the public HTML quote.
 * POST /quotes/:id/send  — Bearer; mint number + email the client the link.
 * GET  /q/:token         — PUBLIC (separate group, quoteLink.ts); renders the HTML page.
 *
 * Quote/line-item/client CRUD stays on /sync. loadQuoteForRender is shared with /q.
 */
export const quotesRoutes = new Hono<AppEnv>();

interface LineItemRow {
  description: string;
  quantity: number;
  unit_price_cents: number;
}

/** UTC YYYY-MM-DD for an epoch-ms instant. */
function utcDate(ms: number): string {
  return new Date(ms).toISOString().slice(0, 10);
}

const APP_URL = "https://snapceipt.cc";
const API_ORIGIN = "https://api.snapceipt.cc";

interface QuoteRenderRow {
  id: string;
  profile_id: string;
  number: string | null;
  client_name: string | null;
  client_email: string | null;
  client_address: string | null;
  client_mobile: string | null;
  gst_enabled: number;
  gst_inclusive: number;
  gst_rate_bp: number | null;
  valid_until: string | null;
  status: string;
  created_at: number;
}

interface ProfileRow {
  name: string;
  abn: string | null;
  business_email: string | null;
  phone: string | null;
  website: string | null;
  address: string | null;
  bank_details: string | null;
  logo_r2_key: string | null;
}

/** R2 object → data-URI (base64), or null when no key / object missing. */
async function logoDataUri(env: Env, key: string | null): Promise<string | null> {
  if (!key) return null;
  const obj = await env.RECEIPTS.get(key);
  if (!obj) return null;
  const bytes = new Uint8Array(await obj.arrayBuffer());
  const contentType = obj.httpMetadata?.contentType ?? "image/png";
  let binary = "";
  const CHUNK = 0x8000;
  for (let i = 0; i < bytes.length; i += CHUNK) {
    binary += String.fromCharCode(...bytes.subarray(i, i + CHUNK));
  }
  return `data:${contentType};base64,${btoa(binary)}`;
}

/**
 * Load a quote + its line items + owning profile and assemble the QuoteHtmlData the
 * HTML template needs. Recomputes totals authoritatively at the quote's snapshotted
 * gst_rate_bp (null ⇒ 1000 = 10%). Returns null when the quote/profile is missing or
 * the quote has no line items (the caller maps null to 404).
 */
export async function loadQuoteForRender(
  env: Env,
  quoteId: string,
  userId: string,
): Promise<QuoteHtmlData | null> {
  const quote = await env.DB.prepare(
    `SELECT id, profile_id, number, client_name, client_email, client_address, client_mobile, gst_enabled, gst_inclusive,
            gst_rate_bp, valid_until, status, created_at
       FROM quotes WHERE id = ? AND user_id = ? AND deleted_at IS NULL`,
  ).bind(quoteId, userId).first<QuoteRenderRow>();
  if (!quote) return null;

  const { results: lineItems } = await env.DB.prepare(
    `SELECT description, quantity, unit_price_cents
       FROM quote_line_items
      WHERE quote_id = ? AND user_id = ? AND deleted_at IS NULL
      ORDER BY sort_order ASC, id ASC`,
  ).bind(quoteId, userId).all<LineItemRow>();
  if (lineItems.length === 0) return null;

  const profile = await env.DB.prepare(
    `SELECT name, abn, business_email, phone, website, address, bank_details, logo_r2_key
       FROM profiles WHERE id = ? AND user_id = ? AND deleted_at IS NULL`,
  ).bind(quote.profile_id, userId).first<ProfileRow>();
  if (!profile) return null;

  const gstEnabled = quote.gst_enabled === 1;
  const gstInclusive = quote.gst_inclusive === 1;
  const totals = recomputeTotals(
    lineItems.map((li): QuoteLineItemAmounts => ({ quantity: li.quantity, unitPriceCents: li.unit_price_cents })),
    gstEnabled,
    gstInclusive,
    quote.gst_rate_bp,
  );

  return {
    number: quote.number,
    issuedDate: utcDate(quote.created_at),
    validUntil: quote.valid_until,
    clientName: quote.client_name,
    clientEmail: quote.client_email,
    clientAddress: quote.client_address,
    clientMobile: quote.client_mobile,
    gstEnabled,
    gstInclusive,
    gstRateBp: quote.gst_rate_bp,
    subtotalCents: totals.subtotalCents,
    gstCents: totals.gstCents,
    totalCents: totals.totalCents,
    business: {
      name: profile.name,
      abn: profile.abn,
      businessEmail: profile.business_email,
      phone: profile.phone,
      website: profile.website,
      address: profile.address,
      bankDetails: profile.bank_details,
    },
    lineItems: lineItems.map((li): QuoteHtmlData["lineItems"][number] => ({
      description: li.description,
      quantity: li.quantity,
      unitPriceCents: li.unit_price_cents,
    })),
    logoDataUri: await logoDataUri(env, profile.logo_r2_key),
    appUrl: APP_URL,
    status: quote.status,
    // token is injected by the /q/:token route (it knows the verified token).
  };
}

quotesRoutes.post("/:id/send", async (c) => {
  const userId = c.var.userId;
  const quoteId = c.req.param("id");

  // 1. Load the quote (scoped to the authed user).
  const quote = await c.env.DB.prepare(
    `SELECT id, profile_id, number, client_name, client_email, gst_enabled, gst_inclusive, gst_rate_bp, valid_until, link_version
       FROM quotes WHERE id = ? AND user_id = ? AND deleted_at IS NULL`,
  ).bind(quoteId, userId).first<{
    id: string; profile_id: string; number: string | null;
    client_name: string | null; client_email: string | null;
    gst_enabled: number; gst_inclusive: number; gst_rate_bp: number | null;
    valid_until: string | null; link_version: number;
  }>();
  if (!quote) throw new ApiError("NOT_FOUND", "Quote not found for this user");

  // 1b. Load the owning profile for the rich email header (name/logo/abn/contact).
  const profile = await c.env.DB.prepare(
    `SELECT name, abn, business_email, phone, logo_r2_key
       FROM profiles WHERE id = ? AND user_id = ? AND deleted_at IS NULL`,
  ).bind(quote.profile_id, userId).first<{
    name: string; abn: string | null; business_email: string | null;
    phone: string | null; logo_r2_key: string | null;
  }>();

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

  // 2b. Email PRECONDITION — validate BEFORE any mutation (spec §8): a missing client
  // email is a hard 400 that must NOT burn a number / flip status / log an outbox row.
  if (!quote.client_email) {
    throw new ApiError("VALIDATION_FAILED", "Quote has no client email to send to");
  }

  // 3. Recompute totals authoritatively at the quote's snapshotted rate (null ⇒ 1000).
  const gstEnabled = quote.gst_enabled === 1;
  const gstInclusive = quote.gst_inclusive === 1;
  const totals = recomputeTotals(
    lineItems.map((li): QuoteLineItemAmounts => ({ quantity: li.quantity, unitPriceCents: li.unit_price_cents })),
    gstEnabled,
    gstInclusive,
    quote.gst_rate_bp,
  );

  // 4. Mint SN-#### only on the first send; a re-send keeps the existing number.
  const number = quote.number ?? (await assignQuoteNumber(c.env.DB, userId));

  // 5. Persist totals + number + status=sent + sent_at.
  const now = nowMs();
  await c.env.DB.prepare(
    `UPDATE quotes
        SET number = ?, status = 'sent', sent_at = ?,
            subtotal_cents = ?, gst_cents = ?, total_cents = ?,
            updated_at = ?
      WHERE id = ? AND user_id = ?`,
  ).bind(number, now, totals.subtotalCents, totals.gstCents, totals.totalCents, now, quoteId, userId).run();

  // 6. Mint the public quote link (carries the quote's current link_version).
  const token = await signQuoteLinkToken(c.env.JWT_SIGNING_KEY, quoteId, userId, quote.link_version);
  const url = `${API_ORIGIN}/q/${token}`;

  // 7. email_outbox row + gated send. export_format is NULL (a link, no file).
  const outboxId = uuidv7();
  await c.env.DB.prepare(
    `INSERT INTO email_outbox (id, user_id, to_email, kind, subject, status, export_format, export_r2_key, related_id, created_at)
     VALUES (?, ?, ?, 'quote_send', ?, 'queued', NULL, NULL, ?, ?)`,
  ).bind(outboxId, userId, quote.client_email, `Quote ${number}`, quoteId, now).run();

  // Attempt the send via the seam (which wraps env.EMAIL.send) inside try/catch; a
  // failure leaves the outbox failed, emailed:false, route still 200s.
  let emailed = false;
  const trader = await c.env.DB.prepare(`SELECT email FROM users WHERE id = ?`)
    .bind(userId).first<{ email: string | null }>();
  const businessContact =
    [profile?.business_email, profile?.phone].filter((v): v is string => !!v).join(" · ") || null;
  try {
    await emailModule.sendQuoteEmail(c.env, {
      to: quote.client_email,
      replyTo: trader?.email ?? "noreply@snapceipt.cc",
      quoteNumber: number,
      clientName: quote.client_name,
      totalCents: totals.totalCents,
      url,
      business: {
        name: profile?.name ?? "",
        logoR2Key: profile?.logo_r2_key ?? null,
        abn: profile?.abn ?? null,
        contact: businessContact,
      },
      lineItems: lineItems.map((li) => ({
        description: li.description,
        quantity: li.quantity,
        amountCents: li.quantity * li.unit_price_cents,
      })),
      subtotalCents: totals.subtotalCents,
      gstCents: totals.gstCents,
      gstEnabled,
      validUntil: quote.valid_until,
      appUrl: APP_URL,
    });
    await c.env.DB.prepare(`UPDATE email_outbox SET status='sent', sent_at=? WHERE id=?`)
      .bind(nowMs(), outboxId).run();
    emailed = true;
  } catch (err) {
    await c.env.DB.prepare(`UPDATE email_outbox SET status='failed', error=? WHERE id=?`)
      .bind(String(err instanceof Error ? err.message : err), outboxId).run();
    emailed = false;
  }

  // 8. Response — the link + whether the email went out + the minted/existing number.
  return c.json({ url, emailed, number });
});

// POST /quotes/:id/link — mint a 30-day signed link to the public HTML quote page.
// Validates the quote loads (owned + has line items) before minting; mints the quote
// number if absent (sharing a link "issues" the quote — the HTML page must show #N).
quotesRoutes.post("/:id/link", async (c) => {
  const userId = c.var.userId;
  const quoteId = c.req.param("id");

  const quote = await c.env.DB.prepare(
    `SELECT number, link_version FROM quotes WHERE id = ? AND user_id = ? AND deleted_at IS NULL`,
  ).bind(quoteId, userId).first<{ number: string | null; link_version: number }>();
  if (!quote) throw new ApiError("NOT_FOUND", "Quote not found for this user");

  const items = await c.env.DB.prepare(
    `SELECT COUNT(*) AS n FROM quote_line_items WHERE quote_id = ? AND user_id = ? AND deleted_at IS NULL`,
  ).bind(quoteId, userId).first<{ n: number }>();
  if (!items || items.n === 0) {
    throw new ApiError("VALIDATION_FAILED", "Cannot link a quote with no line items");
  }

  // Mint the quote number on first link (so the HTML page can show "Quote #N").
  const number = quote.number ?? (await assignQuoteNumber(c.env.DB, userId));
  if (!quote.number) {
    await c.env.DB.prepare(
      `UPDATE quotes SET number = ?, updated_at = ? WHERE id = ? AND user_id = ?`,
    ).bind(number, nowMs(), quoteId, userId).run();
  }

  const token = await signQuoteLinkToken(c.env.JWT_SIGNING_KEY, quoteId, userId, quote.link_version);
  return c.json({ url: `${API_ORIGIN}/q/${token}`, number });
});

// POST /quotes/:id/link/revoke — invalidate every previously-minted public link for this
// quote by bumping its link_version. The next /link or /send mints a fresh, working link.
quotesRoutes.post("/:id/link/revoke", async (c) => {
  const userId = c.var.userId;
  const quoteId = c.req.param("id");
  const res = await c.env.DB.prepare(
    `UPDATE quotes SET link_version = link_version + 1, updated_at = ?
       WHERE id = ? AND user_id = ? AND deleted_at IS NULL`,
  ).bind(nowMs(), quoteId, userId).run();
  if ((res.meta.changes ?? 0) === 0) throw new ApiError("NOT_FOUND", "Quote not found for this user");
  const row = await c.env.DB.prepare(
    `SELECT link_version FROM quotes WHERE id = ? AND user_id = ?`,
  ).bind(quoteId, userId).first<{ link_version: number }>();
  return c.json({ ok: true, linkVersion: row?.link_version ?? 0 });
});
