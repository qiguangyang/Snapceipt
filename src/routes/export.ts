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
import { basEngine, type BasTxn } from "../lib/basEngine";
import { buildBasPdf } from "../lib/pdfBas";
import { buildBasCsv, type BasCsvTxnRow } from "../lib/csvBas";

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
    `SELECT id, name, type, gst_registered, abn FROM profiles WHERE id = ? AND user_id = ? AND deleted_at IS NULL`,
  ).bind(body.profileId, userId).first<{ id: string; name: string; type: string; gst_registered: number; abn: string | null }>();
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

  if (body.format === "bas") {
    // Defence-in-depth gate (the UI never shows the entry for ineligible profiles).
    // Shares the FORBIDDEN code with the ownership gate above; the message text is
    // what distinguishes a BAS-eligibility rejection (asserted by the route tests).
    if (profile.type !== "business" || profile.gst_registered !== 1) {
      throw new ApiError("FORBIDDEN", "BAS export requires a GST-registered business profile");
    }

    // Re-query the slice including the BAS columns.
    const { results: basTxns } = await c.env.DB.prepare(
      `SELECT id, txn_date, merchant, cat_key, amount_cents, gst_cents, deductible_pct, payment_method, note, gst_free, capital, gst_source
         FROM transactions
        WHERE user_id = ? AND profile_id = ? AND txn_date >= ? AND txn_date <= ? AND deleted_at IS NULL
        ORDER BY txn_date DESC, id ASC`,
    ).bind(userId, body.profileId, body.from, body.to).all<BasCsvTxnRow>();

    const bas = basEngine(
      basTxns.map((r): BasTxn => ({ amountCents: r.amount_cents, gstFree: r.gst_free === 1, capital: r.capital === 1 })),
      // Pass the REAL registration flag (contract-faithful): the engine's own
      // !gstRegistered guard (forces 1A=0) stays the single enforcement point, so
      // if the gate above is ever loosened the engine still won't fabricate 1A.
      // The gate guarantees this is 1 here, so this is equivalently `true` today.
      { gstRegistered: profile.gst_registered === 1, manual: { paygInstalmentCents: body.bas?.paygInstalmentCents ?? 0 } },
    );

    const pdf = await buildBasPdf({ profileName: profile.name, abn: profile.abn, periodLabel, bas });
    const csv = await buildBasCsv({
      profileName: profile.name,
      periodLabel,
      rows: basTxns,
      bas,
      receiptKeyByTxnId,
      baseUrl: origin,
      signDownload,
    });

    const pdfKey = `${userId}/exports/${exportId}.pdf`;
    const csvKey = `${userId}/exports/${exportId}.csv`;
    await c.env.RECEIPTS.put(pdfKey, pdf, { httpMetadata: { contentType: "application/pdf" } });
    await c.env.RECEIPTS.put(csvKey, csv, { httpMetadata: { contentType: "text/csv" } });
    const pdfToken = await signDownloadToken(c.env.JWT_SIGNING_KEY, pdfKey);
    const csvToken = await signDownloadToken(c.env.JWT_SIGNING_KEY, csvKey);
    const pdfUrl = `${origin}/export/dl/${pdfToken}`;
    const csvUrl = `${origin}/export/dl/${csvToken}`;
    const expiresAt = nowMs() + DOWNLOAD_TTL_SECONDS * 1000;
    const basEcho = {
      g1: bas.g1, oneA: bas.oneA, oneB: bas.oneB,
      netGst: bas.netGstCents, payg: bas.paygCents, totalPayable: bas.totalPayableCents,
    };

    // No email requested → return the links.
    if (!body.toEmail) {
      return c.json({ pdfUrl, csvUrl, expiresAt, emailed: false, bas: basEcho });
    }

    // Email requested → reuse the export_accountant outbox kind, with the
    // QUOTE-SEND graceful-degrade (try/catch): an absent/failing env.EMAIL
    // degrades to emailed:false WITHOUT losing the links (unlike the accountant
    // branch, which hard-fails).
    const basOutboxId = uuidv7();
    const basNow = nowMs();
    await c.env.DB.prepare(
      `INSERT INTO email_outbox (id, user_id, to_email, kind, subject, status, export_format, export_r2_key, created_at)
       VALUES (?, ?, ?, 'export_accountant', ?, 'queued', 'pdf', ?, ?)`,
    ).bind(basOutboxId, userId, body.toEmail, `Snapceipt BAS — ${profile.name}`, pdfKey, basNow).run();
    const basUser = await c.env.DB.prepare(`SELECT email FROM users WHERE id = ?`)
      .bind(userId).first<{ email: string | null }>();
    let emailed = false;
    try {
      await sendExportEmail(c.env, {
        to: body.toEmail,
        replyTo: basUser?.email ?? "noreply@snapceipt.cc",
        profileName: profile.name,
        periodLabel,
        csv,
        pdf,
      });
      await c.env.DB.prepare(`UPDATE email_outbox SET status='sent', sent_at=? WHERE id=?`)
        .bind(nowMs(), basOutboxId).run();
      emailed = true;
    } catch (err) {
      await c.env.DB.prepare(`UPDATE email_outbox SET status='failed', error=? WHERE id=?`)
        .bind(String(err instanceof Error ? err.message : err), basOutboxId).run();
      emailed = false;
    }
    return c.json({ pdfUrl, csvUrl, expiresAt, emailed, bas: basEcho });
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
