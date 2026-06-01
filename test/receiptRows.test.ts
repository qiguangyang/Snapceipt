import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { coerceCatKey, writeReceiptRows } from "../src/lib/receiptRows";
import type { ExtractedReceipt } from "../src/lib/deepseek";

function receipt(over: Partial<ExtractedReceipt> = {}): ExtractedReceipt {
  return {
    merchant: "ACME Hardware",
    date: "2026-05-30",
    currencyCode: "AUD",
    total: 33,
    gst: 3,
    category: "office",
    deductible: 100,
    lineItems: [{ name: "Drill bits", price: 18 }, { name: "Gloves", price: 12 }],
    confidence: 0.9,
    needsReview: false,
    ...over,
  };
}

async function seed(): Promise<{ userId: string; profileId: string }> {
  const userId = uuidv7();
  const profileId = uuidv7();
  const t = nowMs();
  await env.DB.prepare(
    `INSERT INTO users (id, email, email_verified, plan, created_at, updated_at) VALUES (?, ?, 1, 'free', ?, ?)`,
  ).bind(userId, `${userId}@e.com`, t, t).run();
  await env.DB.prepare(
    `INSERT INTO profiles (id, user_id, name, type, accent_1, accent_2, accent_3, created_at, updated_at)
     VALUES (?, ?, 'Biz', 'business', '#0', '#1', '#2', ?, ?)`,
  ).bind(profileId, userId, t, t).run();
  return { userId, profileId };
}

beforeEach(async () => {
  await env.DB.exec("DELETE FROM line_items");
  await env.DB.exec("DELETE FROM receipt_images");
  await env.DB.exec("DELETE FROM transactions");
  await env.DB.exec("DELETE FROM profiles");
  await env.DB.exec("DELETE FROM users");
});

describe("coerceCatKey", () => {
  it("passes through allowed keys (case-insensitive) and falls back to office", () => {
    expect(coerceCatKey("meals")).toBe("meals");
    expect(coerceCatKey("MEALS")).toBe("meals");
    expect(coerceCatKey("widgets")).toBe("office");
  });
});

describe("writeReceiptRows", () => {
  it("writes a done transaction (dollars->cents), line items, and a receipt_images row", async () => {
    const { userId, profileId } = await seed();
    const txnId = await writeReceiptRows(env.DB, {
      userId, profileId, profileType: "business", receipt: receipt(),
      ocrText: "ACME 33.00", r2Key: `u/${userId}/x.jpg`, contentType: "image/jpeg",
      byteSize: 1234, extractionStatus: "done", extractionModel: "deepseek-chat", nowMs: nowMs(),
    });

    const txn = await env.DB.prepare("SELECT * FROM transactions WHERE id = ?").bind(txnId).first<any>();
    expect(txn.source).toBe("email_in");
    expect(txn.extraction_status).toBe("done");
    expect(txn.profile_id).toBe(profileId);
    expect(txn.amount_cents).toBe(-3300); // expense category -> signed negative
    expect(txn.gst_cents).toBe(300); // positive magnitude
    expect(txn.cat_key).toBe("office");
    expect(txn.mode).toBe("business");
    expect(txn.is_ai).toBe(1);
    expect(txn.last_edited_device_id).toBe("email_in");

    const lines = await env.DB.prepare("SELECT * FROM line_items WHERE transaction_id = ? ORDER BY sort_order").bind(txnId).all<any>();
    expect(lines.results.map((l) => l.price_cents)).toEqual([1800, 1200]);

    const img = await env.DB.prepare("SELECT * FROM receipt_images WHERE transaction_id = ?").bind(txnId).first<any>();
    expect(img.ocr_source).toBe("workers_ai");
    expect(img.source).toBe("email_in");
    expect(img.r2_key).toBe(`u/${userId}/x.jpg`);
    expect(JSON.parse(img.extraction_json).merchant).toBe("ACME Hardware");
  });

  it("stores a positive amount when the category is income", async () => {
    const { userId, profileId } = await seed();
    const txnId = await writeReceiptRows(env.DB, {
      userId, profileId, profileType: "business", receipt: receipt({ category: "income", lineItems: [] }),
      ocrText: null, r2Key: `u/${userId}/z.jpg`, contentType: "image/jpeg",
      byteSize: 10, extractionStatus: "done", extractionModel: "deepseek-chat", nowMs: nowMs(),
    });
    const txn = await env.DB.prepare("SELECT amount_cents, cat_key FROM transactions WHERE id = ?").bind(txnId).first<any>();
    expect(txn.cat_key).toBe("income");
    expect(txn.amount_cents).toBe(3300); // income -> positive
  });

  it("on the failed path writes a failed transaction with no line items, image preserved", async () => {
    const { userId, profileId } = await seed();
    const txnId = await writeReceiptRows(env.DB, {
      userId, profileId, profileType: "personal",
      receipt: { merchant: "", date: "2026-06-01", currencyCode: "AUD", total: 0, gst: null, category: "office", deductible: null, lineItems: [], confidence: 0, needsReview: true },
      ocrText: "garbled", r2Key: `u/${userId}/y.jpg`, contentType: "image/jpeg",
      byteSize: 99, extractionStatus: "failed", extractionModel: null, nowMs: nowMs(),
    });
    const txn = await env.DB.prepare("SELECT * FROM transactions WHERE id = ?").bind(txnId).first<any>();
    expect(txn.extraction_status).toBe("failed");
    expect(txn.amount_cents).toBe(0);
    expect(txn.mode).toBe("personal");
    const lines = await env.DB.prepare("SELECT COUNT(*) c FROM line_items WHERE transaction_id = ?").bind(txnId).first<{ c: number }>();
    expect(lines!.c).toBe(0);
    const img = await env.DB.prepare("SELECT ocr_text, extraction_json FROM receipt_images WHERE transaction_id = ?").bind(txnId).first<any>();
    expect(img.ocr_text).toBe("garbled");
    expect(img.extraction_json).toBeNull();
  });
});
