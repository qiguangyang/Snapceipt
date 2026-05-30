// src/routes/images.ts
import { Hono } from "hono";
import type { AppEnv } from "../env";
import { ApiError } from "../lib/errors";
import { uuidv7 } from "../lib/ids";
import { nowMs } from "../lib/time";

/**
 * Receipt image service.
 *  POST /images      — raw image/jpeg body; metadata via query params; writes to
 *                      R2 + inserts a FK-safe receipt_images row.
 *  GET  /images/*    — wildcard; streams the owner's R2 object (prefix ownership).
 * Both are auth-gated by the global middleware (c.var.userId is set).
 */
export const imageRoutes = new Hono<AppEnv>();

const MAX_BYTES = 6_291_456; // 6 MiB
const OCR_TEXT_CAP = 20_000;

/** Optional non-negative-int query param; returns null when absent/invalid. */
function intParam(c: { req: { query: (k: string) => string | undefined } }, key: string): number | null {
  const raw = c.req.query(key);
  if (raw === undefined) return null;
  const n = Number(raw);
  return Number.isInteger(n) && n >= 0 ? n : null;
}

imageRoutes.post("/", async (c) => {
  const userId = c.var.userId;
  const deviceId = c.var.deviceId;

  // 1. Content-type guard.
  const contentType = c.req.header("content-type") ?? "";
  if (!contentType.includes("image/jpeg")) {
    throw new ApiError("VALIDATION_FAILED", "Expected Content-Type: image/jpeg");
  }

  // 2. Read + size guard.
  const buf = await c.req.arrayBuffer();
  const byteSize = buf.byteLength;
  if (byteSize === 0) throw new ApiError("VALIDATION_FAILED", "Empty image body");
  if (byteSize > MAX_BYTES) {
    throw new ApiError("VALIDATION_FAILED", `Image exceeds ${MAX_BYTES} bytes`);
  }

  // 3. Query metadata.
  const pageIndex = intParam(c, "pageIndex") ?? 0;
  const width = intParam(c, "width");
  const height = intParam(c, "height");
  const reqTxnId = c.req.query("transactionId") ?? null;
  let ocrText = c.req.query("ocrText") ?? null;
  if (ocrText && ocrText.length > OCR_TEXT_CAP) ocrText = ocrText.slice(0, OCR_TEXT_CAP);

  // 4. Write to R2 under the per-user prefix.
  const key = `u/${userId}/${uuidv7()}.jpg`;
  await c.env.RECEIPTS.put(key, buf, { httpMetadata: { contentType: "image/jpeg" } });

  // 5. FK-safe link: keep transactionId ONLY if the txn exists for this user.
  let linkedTxnId: string | null = null;
  if (reqTxnId) {
    const owned = await c.env.DB.prepare(
      "SELECT 1 FROM transactions WHERE id = ? AND user_id = ?",
    ).bind(reqTxnId, userId).first<{ 1: number }>();
    if (owned) linkedTxnId = reqTxnId;
  }

  // 6. Insert the receipt_images row (existing table).
  const now = nowMs();
  await c.env.DB.prepare(
    `INSERT INTO receipt_images
       (id, user_id, profile_id, transaction_id, r2_key, thumb_r2_key, content_type, byte_size,
        width, height, page_index, ocr_text, ocr_source, extraction_json, extraction_model, source,
        created_at, updated_at, deleted_at, rev, last_edited_device_id)
     VALUES (?, ?, NULL, ?, ?, NULL, 'image/jpeg', ?, ?, ?, ?, ?, 'vision_on_device', NULL, NULL, 'scan',
        ?, ?, NULL, 0, ?)`,
  ).bind(
    uuidv7(), userId, linkedTxnId, key, byteSize,
    width, height, pageIndex, ocrText,
    now, now, deviceId,
  ).run();

  return c.json({ imageKey: key, getUrl: `/images/${key}`, byteSize });
});

// Wildcard GET — Hono's :param is single-segment and can't match the slash-bearing
// key, so we read the path tail directly.
imageRoutes.get("/*", async (c) => {
  const key = c.req.path.slice("/images/".length);
  if (!key || !key.startsWith(`u/${c.var.userId}/`)) {
    throw new ApiError("NOT_FOUND", "Image not found");
  }
  const obj = await c.env.RECEIPTS.get(key);
  if (!obj) throw new ApiError("NOT_FOUND", "Image not found");

  // Buffer the object fully rather than streaming obj.body so the R2 read
  // completes before the response returns (a dangling stream blocks the
  // vitest-pool-workers isolated-storage teardown and works against streaming
  // a small receipt JPEG either way).
  const bytes = await obj.arrayBuffer();
  return new Response(bytes, {
    status: 200,
    headers: { "content-type": obj.httpMetadata?.contentType ?? "image/jpeg" },
  });
});
