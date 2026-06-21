import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { mintInboxToken, addressForToken } from "../src/lib/inboxToken";
import { inboundEmailLogic } from "../src/email/inbound";
import { currentPeriod } from "../src/lib/smartScan";
import * as deepseek from "../src/lib/deepseek";

// A multipart/mixed MIME with one base64 image/jpeg attachment.
function mimeWithImage(messageId: string): ArrayBuffer {
  const raw = [
    "From: supplier@example.com",
    "To: receipts@example.com",
    `Message-ID: <${messageId}>`,
    "Subject: Your tax invoice",
    "MIME-Version: 1.0",
    'Content-Type: multipart/mixed; boundary="BOUND"',
    "",
    "--BOUND",
    "Content-Type: text/plain; charset=utf-8",
    "",
    "Receipt attached.",
    "--BOUND",
    'Content-Type: image/jpeg; name="receipt.jpg"',
    "Content-Transfer-Encoding: base64",
    'Content-Disposition: attachment; filename="receipt.jpg"',
    "",
    "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBD",
    "--BOUND--",
    "",
  ].join("\r\n");
  return new TextEncoder().encode(raw).buffer as ArrayBuffer;
}

// A MIME with NO attachments (text only).
function mimeTextOnly(messageId: string): ArrayBuffer {
  const raw = [
    "From: supplier@example.com",
    "To: receipts@example.com",
    `Message-ID: <${messageId}>`,
    "Subject: hi",
    "Content-Type: text/plain; charset=utf-8",
    "",
    "no attachment here",
    "",
  ].join("\r\n");
  return new TextEncoder().encode(raw).buffer as ArrayBuffer;
}

async function seedProfileWithInbox(type = "business"): Promise<{ userId: string; profileId: string; address: string }> {
  const userId = uuidv7();
  const profileId = uuidv7();
  const t = nowMs();
  await env.DB.prepare(
    `INSERT INTO users (id, email, email_verified, plan, created_at, updated_at) VALUES (?, ?, 1, 'free', ?, ?)`,
  ).bind(userId, `${userId}@e.com`, t, t).run();
  await env.DB.prepare(
    `INSERT INTO profiles (id, user_id, name, type, accent_1, accent_2, accent_3, created_at, updated_at)
     VALUES (?, ?, 'Biz', ?, '#0', '#1', '#2', ?, ?)`,
  ).bind(profileId, userId, type, t, t).run();
  const token = await mintInboxToken(env.DB, userId, profileId, t);
  return { userId, profileId, address: addressForToken(token) };
}

// Hermetic env: stub OCR + stub extraction.
function emailEnv(over: Record<string, unknown> = {}) {
  return { ...env, E2E_EMAIL_MODE: "1", E2E_EXTRACT_MODE: "1", ...over } as typeof env;
}

beforeEach(async () => {
  await env.DB.exec("DELETE FROM line_items");
  await env.DB.exec("DELETE FROM receipt_images");
  await env.DB.exec("DELETE FROM transactions");
  await env.DB.exec("DELETE FROM inbound_email_log");
  await env.DB.exec("DELETE FROM profile_inbox_tokens");
  await env.DB.exec("DELETE FROM smart_scan_usage");
  await env.DB.exec("DELETE FROM profiles");
  await env.DB.exec("DELETE FROM users");
});

describe("inboundEmailLogic", () => {
  it("rejects an unknown inbox alias and writes no rows", async () => {
    const res = await inboundEmailLogic(emailEnv(), {
      to: "r.deadbeefdeadbeefdeadbeefdeadbeef@in.snapceipt.cc",
      from: "x@e.com", messageId: "<m1>", raw: mimeWithImage("m1"),
    }, nowMs());
    expect(res).toEqual({ status: "rejected", reason: "unknown_inbox" });
    const c = await env.DB.prepare("SELECT COUNT(*) c FROM transactions").first<{ c: number }>();
    expect(c!.c).toBe(0);
  });

  it("rejects a non-r. recipient (unknown_inbox)", async () => {
    const res = await inboundEmailLogic(emailEnv(), {
      to: "noreply@snapceipt.cc", from: "x@e.com", messageId: "<m1b>", raw: mimeWithImage("m1b"),
    }, nowMs());
    expect(res).toEqual({ status: "rejected", reason: "unknown_inbox" });
  });

  it("rejects an email with no image attachment", async () => {
    const { address } = await seedProfileWithInbox();
    const res = await inboundEmailLogic(emailEnv(), {
      to: address, from: "x@e.com", messageId: "<m2>", raw: mimeTextOnly("m2"),
    }, nowMs());
    expect(res).toEqual({ status: "rejected", reason: "no_image" });
  });

  it("creates a done transaction with the resolved profile on the happy path", async () => {
    const { profileId, address } = await seedProfileWithInbox();
    const res = await inboundEmailLogic(emailEnv(), {
      to: address, from: "x@e.com", messageId: "<m3>", raw: mimeWithImage("m3"),
    }, nowMs());
    expect(res.status).toBe("created");
    if (res.status !== "created") return;
    expect(res.extraction).toBe("done");
    const txn = await env.DB.prepare("SELECT * FROM transactions WHERE id = ?").bind(res.transactionId).first<any>();
    expect(txn.source).toBe("email_in");
    expect(txn.extraction_status).toBe("done");
    expect(txn.profile_id).toBe(profileId);
    expect(txn.amount_cents).toBe(-3300); // STUB_OCR_TEXT -> total 33.00, office (expense) -> signed negative
    const img = await env.DB.prepare("SELECT COUNT(*) c FROM receipt_images WHERE transaction_id = ?").bind(res.transactionId).first<{ c: number }>();
    expect(img!.c).toBe(1);
  });

  it("is idempotent on Message-ID — a redelivery creates no second transaction", async () => {
    const { address } = await seedProfileWithInbox();
    const msg = { to: address, from: "x@e.com", messageId: "<dup>", raw: mimeWithImage("dup") };
    const first = await inboundEmailLogic(emailEnv(), { ...msg, raw: mimeWithImage("dup") }, nowMs());
    const second = await inboundEmailLogic(emailEnv(), { ...msg, raw: mimeWithImage("dup") }, nowMs());
    expect(first.status).toBe("created");
    expect(second).toEqual({ status: "duplicate" });
    const c = await env.DB.prepare("SELECT COUNT(*) c FROM transactions").first<{ c: number }>();
    expect(c!.c).toBe(1);
  });

  it("skips AI extraction when the user is over the monthly smart-scan cap (no spend, image kept)", async () => {
    const { userId, address } = await seedProfileWithInbox();
    const t = nowMs();
    // Seed usage AT the free cap (10) so the next email-in is over cap.
    await env.DB.prepare(
      "INSERT INTO smart_scan_usage (user_id, period, count, updated_at) VALUES (?, ?, ?, ?)",
    ).bind(userId, currentPeriod(t), 10, t).run();

    const res = await inboundEmailLogic(emailEnv(), {
      to: address, from: "x@e.com", messageId: "<cap1>", raw: mimeWithImage("cap1"),
    }, t);
    expect(res.status).toBe("created");
    if (res.status !== "created") return;
    expect(res.extraction).toBe("failed"); // AI skipped -> needs-review txn
    // The receipt image is still stored (never lost).
    const img = await env.DB.prepare("SELECT COUNT(*) c FROM receipt_images WHERE transaction_id = ?")
      .bind(res.transactionId).first<{ c: number }>();
    expect(img!.c).toBe(1);
    // Usage was NOT incremented past the cap.
    const usage = await env.DB.prepare("SELECT count FROM smart_scan_usage WHERE user_id = ? AND period = ?")
      .bind(userId, currentPeriod(t)).first<{ count: number }>();
    expect(usage!.count).toBe(10);
    const log = await env.DB.prepare("SELECT reason FROM inbound_email_log WHERE message_id = ?")
      .bind("<cap1>").first<{ reason: string | null }>();
    expect(log!.reason).toBe("over_cap");
  });

  it("rate-limits a flood to one alias (rejected: rate_limited)", async () => {
    const { userId, profileId } = await seedProfileWithInbox();
    const t = nowMs();
    const token = await mintInboxToken(env.DB, userId, profileId, t);
    // Pre-seed the per-alias hourly counter at the limit (20).
    const bucket = Math.floor(t / (60 * 60 * 1000));
    await env.KV.put(`rl:inbound:${token}:${bucket}`, "20");

    const res = await inboundEmailLogic(emailEnv(), {
      to: addressForToken(token), from: "x@e.com", messageId: "<rl1>", raw: mimeWithImage("rl1"),
    }, t);
    expect(res).toEqual({ status: "rejected", reason: "rate_limited" });
    // No transaction created for the throttled message.
    const c = await env.DB.prepare("SELECT COUNT(*) c FROM transactions").first<{ c: number }>();
    expect(c!.c).toBe(0);
  });

  it("creates a failed transaction (image preserved) when extraction throws", async () => {
    const { address } = await seedProfileWithInbox();
    const spy = vi.spyOn(deepseek, "runDeepseekExtraction").mockRejectedValue(new Error("boom"));
    try {
      // DEEPSEEK_API_KEY present + E2E_EXTRACT_MODE unset => real extraction path => the spy throws.
      const res = await inboundEmailLogic(
        emailEnv({ E2E_EXTRACT_MODE: undefined, DEEPSEEK_API_KEY: "real-key" }),
        { to: address, from: "x@e.com", messageId: "<m4>", raw: mimeWithImage("m4") },
        nowMs(),
      );
      expect(res.status).toBe("created");
      if (res.status !== "created") return;
      expect(res.extraction).toBe("failed");
      const txn = await env.DB.prepare("SELECT extraction_status FROM transactions WHERE id = ?").bind(res.transactionId).first<any>();
      expect(txn.extraction_status).toBe("failed");
      const img = await env.DB.prepare("SELECT ocr_text FROM receipt_images WHERE transaction_id = ?").bind(res.transactionId).first<any>();
      expect(img.ocr_text).not.toBeNull(); // OCR stub still ran
    } finally {
      spy.mockRestore();
    }
  });
});
