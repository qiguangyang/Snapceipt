// src/lib/receiptRows.ts
import type { ExtractedReceipt } from "./deepseek";
import { uuidv7 } from "./ids";

const CAT_KEYS = [
  "meals", "groceries", "fuel", "software", "office",
  "home", "health", "travel", "income", "custom",
] as const;
export type CatKey = (typeof CAT_KEYS)[number];

const DEVICE = "email_in";

/** Map a free-text category onto the transactions.cat_key CHECK set; fallback office. */
export function coerceCatKey(category: string): CatKey {
  const c = category.trim().toLowerCase();
  return (CAT_KEYS as readonly string[]).includes(c) ? (c as CatKey) : "office";
}

function toCents(dollars: number): number {
  return Math.round(dollars * 100);
}
function clampPct(n: number | null): number | null {
  if (n == null) return null;
  return Math.max(0, Math.min(100, Math.round(n)));
}

export interface WriteReceiptArgs {
  userId: string;
  profileId: string;
  profileType: string; // 'business' | 'personal'
  receipt: ExtractedReceipt;
  ocrText: string | null;
  r2Key: string;
  contentType: string;
  byteSize: number;
  extractionStatus: "done" | "failed";
  extractionModel: string | null;
  nowMs: number;
}

/**
 * Insert a transactions row (+ line_items on the done path) + a receipt_images
 * row, all owned by (userId, profileId). Amounts in ExtractedReceipt are dollars
 * — converted to integer cents here. Returns the new transaction id.
 *
 * All inserts run in a single `db.batch()` so they commit atomically — a failure
 * mid-write can never orphan a transaction without its image (mirrors the
 * batched write path in src/routes/sync.ts).
 */
export async function writeReceiptRows(db: D1Database, a: WriteReceiptArgs): Promise<string> {
  const txnId = uuidv7();
  const r = a.receipt;
  const mode = a.profileType === "business" ? "business" : "personal";
  const catKey = coerceCatKey(r.category);
  // amount_cents is SIGNED on the device (expense < 0, income > 0). Receipt totals
  // are positive dollars, so negate unless the category is income. gst_cents stays a
  // positive magnitude (matches the on-device convention).
  const sign = catKey === "income" ? 1 : -1;
  const amountCents = sign * toCents(r.total);
  const gstCents = r.gst == null ? null : toCents(r.gst);

  const statements: D1PreparedStatement[] = [
    db
      .prepare(
        `INSERT INTO transactions
           (id, user_id, profile_id, merchant, category_id, cat_key, amount_cents, currency, txn_date,
            mode, tax_label, deductible_pct, payment_method, is_ai, note, gst_cents, logbook_link,
            mileage_trip_id, source, extraction_status, created_at, updated_at, deleted_at, rev, last_edited_device_id)
         VALUES (?, ?, ?, ?, NULL, ?, ?, 'AUD', ?, ?, NULL, ?, NULL, 1, NULL, ?, NULL, NULL, 'email_in', ?, ?, ?, NULL, 0, ?)`,
      )
      .bind(
        txnId, a.userId, a.profileId, r.merchant, catKey, amountCents, r.date,
        mode, clampPct(r.deductible), gstCents, a.extractionStatus, a.nowMs, a.nowMs, DEVICE,
      ),
  ];

  if (a.extractionStatus === "done") {
    for (const [i, li] of r.lineItems.entries()) {
      statements.push(
        db
          .prepare(
            `INSERT INTO line_items
               (id, user_id, transaction_id, name, price_cents, quantity, sort_order, created_at, updated_at, deleted_at, rev, last_edited_device_id)
             VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?, NULL, 0, ?)`,
          )
          .bind(uuidv7(), a.userId, txnId, li.name, toCents(li.price), i, a.nowMs, a.nowMs, DEVICE),
      );
    }
  }

  statements.push(
    db
      .prepare(
        `INSERT INTO receipt_images
           (id, user_id, profile_id, transaction_id, r2_key, thumb_r2_key, content_type, byte_size,
            width, height, page_index, ocr_text, ocr_source, extraction_json, extraction_model, source,
            created_at, updated_at, deleted_at, rev, last_edited_device_id)
         VALUES (?, ?, ?, ?, ?, NULL, ?, ?, NULL, NULL, 0, ?, 'workers_ai', ?, ?, 'email_in', ?, ?, NULL, 0, ?)`,
      )
      .bind(
        uuidv7(), a.userId, a.profileId, txnId, a.r2Key, a.contentType, a.byteSize,
        a.ocrText, a.extractionStatus === "done" ? JSON.stringify(r) : null, a.extractionModel,
        a.nowMs, a.nowMs, DEVICE,
      ),
  );

  await db.batch(statements);
  return txnId;
}
