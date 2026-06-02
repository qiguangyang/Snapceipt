import { Hono } from "hono";
import type { AppEnv } from "../env";
import { ApiError } from "../lib/errors";
import { uuidv7 } from "../lib/ids";
import { nowMs } from "../lib/time";
import { validate } from "./auth";
import { exportRequestSchema } from "../schemas/export";
import { buildExportCsv, type CsvTxnRow } from "../lib/csvExport";
import { buildExportPdf, type PdfTxnRow } from "../lib/pdfExport";
import { sendExportEmail } from "../lib/email";
import { signDownloadToken, verifyDownloadToken, DOWNLOAD_TTL_SECONDS } from "../lib/exportToken";

/**
 * POST /export        — Bearer (global auth) + rate tier "export" (app.ts).
 * GET  /export/dl/:token — PUBLIC (in PUBLIC_PATHS); streams the signed R2 object.
 */
export const exportRoutes = new Hono<AppEnv>();

/** A transaction row as queried from D1 for the period (snake_case). */
interface TxnRow {
  id: string;
  txn_date: string;
  merchant: string;
  cat_key: string;
  amount_cents: number;
  gst_cents: number | null;
  deductible_pct: number | null;
  payment_method: string | null;
  note: string | null;
}

/** Compute the deductible + GST totals + top-5 categories for the PDF. */
function summarize(rows: TxnRow[]) {
  let deductibleTotalCents = 0;
  let gstTotalCents = 0;
  const byCat = new Map<string, number>();
  for (const r of rows) {
    if (r.amount_cents < 0) {
      const spend = -r.amount_cents;
      if (r.deductible_pct != null) {
        deductibleTotalCents += Math.round((spend * r.deductible_pct) / 100);
      }
      if (r.gst_cents != null) gstTotalCents += r.gst_cents;
      byCat.set(r.cat_key, (byCat.get(r.cat_key) ?? 0) + spend);
    }
  }
  const topCategories = [...byCat.entries()]
    .map(([catKey, spendCents]) => ({ catKey, spendCents }))
    .sort((a, b) => b.spendCents - a.spendCents)
    .slice(0, 5);
  return { deductibleTotalCents, gstTotalCents, topCategories };
}

exportRoutes.post("/", validate("json", exportRequestSchema), async (c) => {
  const userId = c.var.userId;
  const body = c.req.valid("json");

  // from <= to (lexical compare is valid for YYYY-MM-DD).
  if (body.from > body.to) {
    throw new ApiError("VALIDATION_FAILED", "`from` must be <= `to`");
  }

  // Profile ownership (scoped to the authed user).
  const profile = await c.env.DB.prepare(
    `SELECT id, name FROM profiles WHERE id = ? AND user_id = ? AND deleted_at IS NULL`,
  ).bind(body.profileId, userId).first<{ id: string; name: string }>();
  if (!profile) throw new ApiError("FORBIDDEN", "Profile not found for this user");

  // Period transactions (deterministic: txn_date DESC, id ASC).
  const { results: txns } = await c.env.DB.prepare(
    `SELECT id, txn_date, merchant, cat_key, amount_cents, gst_cents, deductible_pct, payment_method, note
       FROM transactions
      WHERE user_id = ? AND profile_id = ? AND txn_date >= ? AND txn_date <= ? AND deleted_at IS NULL
      ORDER BY txn_date DESC, id ASC`,
  ).bind(userId, body.profileId, body.from, body.to).all<TxnRow>();

  // Receipt image keys for those transactions (first image per txn).
  const receiptKeyByTxnId = new Map<string, string>();
  const { results: imgs } = await c.env.DB.prepare(
    `SELECT transaction_id, r2_key FROM receipt_images
      WHERE user_id = ? AND profile_id = ? AND transaction_id IS NOT NULL AND deleted_at IS NULL
      ORDER BY created_at ASC`,
  ).bind(userId, body.profileId).all<{ transaction_id: string; r2_key: string }>();
  for (const img of imgs) {
    if (!receiptKeyByTxnId.has(img.transaction_id)) {
      receiptKeyByTxnId.set(img.transaction_id, img.r2_key);
    }
  }

  const periodLabel = `${body.from} to ${body.to}`;
  const exportId = uuidv7();
  const origin = new URL(c.req.url).origin;
  const signDownload = (r2Key: string) => signDownloadToken(c.env.JWT_SIGNING_KEY, r2Key);

  // Build the CSV (needed for csv + accountant).
  const buildCsv = () =>
    buildExportCsv({
      profileName: profile.name,
      periodLabel,
      rows: txns as CsvTxnRow[],
      receiptKeyByTxnId,
      baseUrl: origin,
      signDownload,
    });

  // Build the PDF (needed for pdf + accountant).
  const buildPdf = () => {
    const s = summarize(txns);
    return buildExportPdf({
      profileName: profile.name,
      periodLabel,
      deductibleTotalCents: s.deductibleTotalCents,
      gstTotalCents: s.gstTotalCents,
      topCategories: s.topCategories,
      rows: txns as PdfTxnRow[],
    });
  };

  if (body.format === "csv") {
    const csv = await buildCsv();
    const key = `${userId}/exports/${exportId}.csv`;
    await c.env.RECEIPTS.put(key, csv, { httpMetadata: { contentType: "text/csv" } });
    const token = await signDownloadToken(c.env.JWT_SIGNING_KEY, key);
    return c.json({ url: `${origin}/export/dl/${token}`, expiresAt: nowMs() + DOWNLOAD_TTL_SECONDS * 1000 });
  }

  if (body.format === "pdf") {
    const pdf = await buildPdf();
    const key = `${userId}/exports/${exportId}.pdf`;
    await c.env.RECEIPTS.put(key, pdf, { httpMetadata: { contentType: "application/pdf" } });
    const token = await signDownloadToken(c.env.JWT_SIGNING_KEY, key);
    return c.json({ url: `${origin}/export/dl/${token}`, expiresAt: nowMs() + DOWNLOAD_TTL_SECONDS * 1000 });
  }

  // accountant: generate both, store the PDF, log the outbox row, send the email.
  const csv = await buildCsv();
  const pdf = await buildPdf();
  const pdfKey = `${userId}/exports/${exportId}.pdf`;
  await c.env.RECEIPTS.put(pdfKey, pdf, { httpMetadata: { contentType: "application/pdf" } });

  const toEmail = body.toEmail!; // schema guarantees presence for accountant
  const outboxId = uuidv7();
  const now = nowMs();
  await c.env.DB.prepare(
    `INSERT INTO email_outbox (id, user_id, to_email, kind, subject, status, export_format, export_r2_key, created_at)
     VALUES (?, ?, ?, 'export_accountant', ?, 'queued', 'pdf', ?, ?)`,
  ).bind(outboxId, userId, toEmail, `Snapceipt export — ${profile.name}`, pdfKey, now).run();

  // The user's email is the reply-to.
  const user = await c.env.DB.prepare(`SELECT email FROM users WHERE id = ?`)
    .bind(userId).first<{ email: string | null }>();

  try {
    await sendExportEmail(c.env, {
      to: toEmail,
      replyTo: user?.email ?? "noreply@snapceipt.cc",
      profileName: profile.name,
      periodLabel,
      csv,
      pdf,
    });
    await c.env.DB.prepare(`UPDATE email_outbox SET status='sent', sent_at=? WHERE id=?`)
      .bind(nowMs(), outboxId).run();
    return c.json({ status: "sent", outboxId });
  } catch (err) {
    await c.env.DB.prepare(`UPDATE email_outbox SET status='failed', error=? WHERE id=?`)
      .bind(String(err instanceof Error ? err.message : err), outboxId).run();
    throw new ApiError("INTERNAL", "Failed to send export email");
  }
});

// PUBLIC: GET /export/dl/:token — verify the signed token + stream the R2 object.
exportRoutes.get("/dl/:token", async (c) => {
  const token = c.req.param("token");
  let r2Key: string;
  try {
    ({ r2Key } = await verifyDownloadToken(c.env.JWT_SIGNING_KEY, token));
  } catch {
    throw new ApiError("FORBIDDEN", "Invalid or expired download link");
  }
  const obj = await c.env.RECEIPTS.get(r2Key);
  if (!obj) throw new ApiError("NOT_FOUND", "Export not found");

  // Buffer fully (mirrors images.ts) so the R2 read completes before the
  // response returns — a dangling stream blocks vitest-pool-workers teardown.
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
