import { env } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { mintInboxToken, addressForToken } from "../src/lib/inboxToken";
import { inboundEmailLogic } from "../src/email/inbound";
import { currentPeriod } from "../src/lib/smartScan";
import * as deepseek from "../src/lib/deepseek";
import * as apns from "../src/lib/apns";

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

async function seedProfileWithInbox(
  type = "business",
  plan: "free" | "pro" = "pro",
): Promise<{ userId: string; profileId: string; address: string }> {
  const userId = uuidv7();
  const profileId = uuidv7();
  const t = nowMs();
  // plan defaults to "pro" because email-in is now Pro-only: most inbound tests want the
  // gate OPEN so they can exercise the dedup/image/extraction path. A live subscription
  // (active, no expiry) so isProUser() returns true. Free callers pass plan:"free".
  if (plan === "pro") {
    await env.DB.prepare(
      `INSERT INTO users (id, email, email_verified, plan, subscription_status, subscription_expires_at, created_at, updated_at)
       VALUES (?, ?, 1, 'pro', 'active', NULL, ?, ?)`,
    ).bind(userId, `${userId}@e.com`, t, t).run();
  } else {
    await env.DB.prepare(
      `INSERT INTO users (id, email, email_verified, plan, created_at, updated_at) VALUES (?, ?, 1, 'free', ?, ?)`,
    ).bind(userId, `${userId}@e.com`, t, t).run();
  }
  await env.DB.prepare(
    `INSERT INTO profiles (id, user_id, name, type, accent_1, accent_2, accent_3, created_at, updated_at)
     VALUES (?, ?, 'Biz', ?, '#0', '#1', '#2', ?, ?)`,
  ).bind(profileId, userId, type, t, t).run();
  const token = await mintInboxToken(env.DB, userId, profileId, t);
  return { userId, profileId, address: addressForToken(token) };
}

/** Seed one push-enabled device with an apns_token for `userId` so notifyEmailInReceipt's
 * device query returns a row and sendPush is invoked. */
async function seedDevice(userId: string, apnsToken = `tok-${uuidv7()}`): Promise<void> {
  const t = nowMs();
  await env.DB.prepare(
    `INSERT INTO devices (id, user_id, platform, apns_token, push_enabled, created_at, updated_at)
     VALUES (?, ?, 'ios', ?, 1, ?, ?)`,
  ).bind(uuidv7(), userId, apnsToken, t, t).run();
}

/** A Gemini-shaped fetch response carrying `obj` as the JSON receipt in the first candidate part. */
function mockGemini(obj: unknown) {
  return vi.fn(async () => ({
    ok: true,
    status: 200,
    json: async () => ({ candidates: [{ content: { parts: [{ text: JSON.stringify(obj) }] } }] }),
  })) as unknown as typeof fetch;
}

// Hermetic env: stub OCR + stub extraction.
function emailEnv(over: Record<string, unknown> = {}) {
  return { ...env, E2E_EMAIL_MODE: "1", E2E_EXTRACT_MODE: "1", ...over } as typeof env;
}

const ORIGINAL_FETCH = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = ORIGINAL_FETCH; // the Gemini test swaps fetch — always restore it.
});

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
    // Owner is Pro (email-in is Pro-only) so the cap is the PRO cap (500). Seed usage AT it
    // so the next email-in is over cap.
    await env.DB.prepare(
      "INSERT INTO smart_scan_usage (user_id, period, count, updated_at) VALUES (?, ?, ?, ?)",
    ).bind(userId, currentPeriod(t), 500, t).run();

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
    expect(usage!.count).toBe(500);
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

  it("creates a failed transaction (image preserved) when vision extraction throws", async () => {
    const { address } = await seedProfileWithInbox();
    const spy = vi.spyOn(deepseek, "runGeminiVisionExtraction").mockRejectedValue(new Error("boom"));
    try {
      // GEMINI_API_KEY present + E2E_EXTRACT_MODE unset => real vision path => the spy throws.
      const res = await inboundEmailLogic(
        emailEnv({ E2E_EXTRACT_MODE: undefined, GEMINI_API_KEY: "real-key" }),
        { to: address, from: "x@e.com", messageId: "<m4>", raw: mimeWithImage("m4") },
        nowMs(),
      );
      expect(res.status).toBe("created");
      if (res.status !== "created") return;
      expect(res.extraction).toBe("failed");
      const txn = await env.DB.prepare("SELECT extraction_status FROM transactions WHERE id = ?").bind(res.transactionId).first<any>();
      expect(txn.extraction_status).toBe("failed");
      // No OCR step anymore — ocr_text is stored null.
      const img = await env.DB.prepare("SELECT ocr_text FROM receipt_images WHERE transaction_id = ?").bind(res.transactionId).first<any>();
      expect(img.ocr_text).toBeNull();
    } finally {
      spy.mockRestore();
    }
  });

  it("marks the transaction failed when vision returns an empty/implausible result (sanity gate)", async () => {
    const { address } = await seedProfileWithInbox();
    // A successful (usedLlm:true) vision extraction with no total and no items must NOT persist
    // a zeros receipt — the sanity gate flips it to failed (image kept for review).
    const spy = vi.spyOn(deepseek, "runGeminiVisionExtraction").mockResolvedValue({
      receipt: {
        merchant: "", date: "2026-06-24", currencyCode: "AUD", total: 0, gst: null,
        category: "office", deductible: null, lineItems: [], confidence: 0.3, needsReview: true,
      },
      meta: { model: "gemini-3.1-flash-lite", attempts: 1, stub: false, usedLlm: true },
    });
    try {
      const res = await inboundEmailLogic(
        emailEnv({ E2E_EXTRACT_MODE: undefined, GEMINI_API_KEY: "real-key" }),
        { to: address, from: "x@e.com", messageId: "<m5>", raw: mimeWithImage("m5") },
        nowMs(),
      );
      expect(res.status).toBe("created");
      if (res.status !== "created") return;
      expect(res.extraction).toBe("failed");
      const txn = await env.DB.prepare("SELECT extraction_status FROM transactions WHERE id = ?").bind(res.transactionId).first<any>();
      expect(txn.extraction_status).toBe("failed");
      const img = await env.DB.prepare("SELECT COUNT(*) c FROM receipt_images WHERE transaction_id = ?").bind(res.transactionId).first<{ c: number }>();
      expect(img!.c).toBe(1); // image kept
    } finally {
      spy.mockRestore();
    }
  });

  it("bounces a free user's inbound email (pro_only) with no side effects", async () => {
    // FREE owner + a real GEMINI_API_KEY (so the real path WOULD run if not gated).
    const { address } = await seedProfileWithInbox("business", "free");
    const fetchSpy = vi.fn();
    globalThis.fetch = fetchSpy as unknown as typeof fetch;
    const res = await inboundEmailLogic(
      emailEnv({ E2E_EXTRACT_MODE: undefined, GEMINI_API_KEY: "real-key" }),
      { to: address, from: "x@e.com", messageId: "<pro1>", raw: mimeWithImage("pro1") },
      nowMs(),
    );
    expect(res).toEqual({ status: "rejected", reason: "pro_only" });
    // Zero side effects: no transaction, no stored image, no inbound_email_log row, no Gemini call.
    const txn = await env.DB.prepare("SELECT COUNT(*) c FROM transactions").first<{ c: number }>();
    expect(txn!.c).toBe(0);
    const img = await env.DB.prepare("SELECT COUNT(*) c FROM receipt_images").first<{ c: number }>();
    expect(img!.c).toBe(0);
    const log = await env.DB.prepare("SELECT COUNT(*) c FROM inbound_email_log").first<{ c: number }>();
    expect(log!.c).toBe(0);
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it("extracts a pro user's inbound email via Gemini (mocked)", async () => {
    const { address } = await seedProfileWithInbox("business", "pro");
    globalThis.fetch = mockGemini({
      merchant: "Coles", date: "2026-06-20", currencyCode: "AUD", total: 34.87, gst: 0.36,
      category: "groceries", deductible: 0, lineItems: [{ name: "Milk", price: 3.5 }], confidence: 0.9,
    });
    const res = await inboundEmailLogic(
      emailEnv({ E2E_EXTRACT_MODE: undefined, GEMINI_API_KEY: "real-key" }),
      { to: address, from: "x@e.com", messageId: "<pro2>", raw: mimeWithImage("pro2") },
      nowMs(),
    );
    expect(res.status).toBe("created");
    if (res.status !== "created") return;
    expect(res.extraction).toBe("done");
    const txn = await env.DB.prepare("SELECT merchant, amount_cents FROM transactions WHERE id = ?")
      .bind(res.transactionId).first<{ merchant: string; amount_cents: number }>();
    expect(txn!.merchant).toBe("Coles");
    expect(txn!.amount_cents).toBe(-3487); // 34.87, groceries (expense) -> signed negative
  });

  it("pushes on a created email-in receipt", async () => {
    const { userId, address } = await seedProfileWithInbox("business", "pro");
    await seedDevice(userId);
    globalThis.fetch = mockGemini({
      merchant: "Coles", date: "2026-06-20", currencyCode: "AUD", total: 34.87, gst: 0.36,
      category: "groceries", deductible: 0, lineItems: [{ name: "Milk", price: 3.5 }], confidence: 0.9,
    });
    const spy = vi.spyOn(apns, "sendPush").mockResolvedValue({ stub: false, status: 200 });
    try {
      const res = await inboundEmailLogic(
        emailEnv({ E2E_EXTRACT_MODE: undefined, GEMINI_API_KEY: "real-key" }),
        { to: address, from: "x@e.com", messageId: "<push1>", raw: mimeWithImage("push1") },
        nowMs(),
      );
      expect(res.status).toBe("created");
      expect(spy).toHaveBeenCalledTimes(1);
      expect(spy.mock.calls[0][2].type).toBe("email_in");
    } finally {
      spy.mockRestore();
    }
  });

  it("does not push when a free user is bounced", async () => {
    const { userId, address } = await seedProfileWithInbox("business", "free");
    await seedDevice(userId);
    const spy = vi.spyOn(apns, "sendPush").mockResolvedValue({ stub: false, status: 200 });
    try {
      const res = await inboundEmailLogic(emailEnv(), {
        to: address, from: "x@e.com", messageId: "<push2>", raw: mimeWithImage("push2"),
      }, nowMs());
      expect(res).toEqual({ status: "rejected", reason: "pro_only" });
      expect(spy).not.toHaveBeenCalled();
    } finally {
      spy.mockRestore();
    }
  });

  it("still creates the txn if the push throws (best-effort)", async () => {
    const { userId, address } = await seedProfileWithInbox("business", "pro");
    await seedDevice(userId);
    globalThis.fetch = mockGemini({
      merchant: "Coles", date: "2026-06-20", currencyCode: "AUD", total: 34.87, gst: 0.36,
      category: "groceries", deductible: 0, lineItems: [{ name: "Milk", price: 3.5 }], confidence: 0.9,
    });
    const spy = vi.spyOn(apns, "sendPush").mockRejectedValue(new Error("apns down"));
    try {
      const res = await inboundEmailLogic(
        emailEnv({ E2E_EXTRACT_MODE: undefined, GEMINI_API_KEY: "real-key" }),
        { to: address, from: "x@e.com", messageId: "<push3>", raw: mimeWithImage("push3") },
        nowMs(),
      );
      expect(res.status).toBe("created");
    } finally {
      spy.mockRestore();
    }
  });

  // ---- multi-attachment + PDF ----
  const IMG_B64 = "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBD";
  const PDF_B64 = "JVBERi0xLjQKJeLjz9MKMSAwIG9iago8PC9UeXBlL0NhdGFsb2c+PgplbmRvYmoK"; // "%PDF-1.4 ..."

  /** multipart/mixed MIME carrying N attachments; each part may override disposition. */
  function mimeWithParts(
    messageId: string,
    parts: { mime: string; b64: string; filename?: string; disposition?: string }[],
  ): ArrayBuffer {
    const lines = [
      "From: supplier@example.com",
      "To: receipts@example.com",
      `Message-ID: <${messageId}>`,
      "Subject: receipts",
      "MIME-Version: 1.0",
      'Content-Type: multipart/mixed; boundary="BOUND"',
      "",
      "--BOUND",
      "Content-Type: text/plain; charset=utf-8",
      "",
      "Receipts attached.",
    ];
    parts.forEach((p, i) => {
      const name = p.filename ?? `file${i}`;
      lines.push(
        "--BOUND",
        `Content-Type: ${p.mime}; name="${name}"`,
        "Content-Transfer-Encoding: base64",
        `Content-Disposition: ${p.disposition ?? "attachment"}; filename="${name}"`,
        "",
        p.b64,
      );
    });
    lines.push("--BOUND--", "");
    return new TextEncoder().encode(lines.join("\r\n")).buffer as ArrayBuffer;
  }

  it("creates one receipt per attachment for a multi-image email", async () => {
    const { profileId, address } = await seedProfileWithInbox("business", "pro");
    const res = await inboundEmailLogic(emailEnv(), {
      to: address, from: "x@e.com", messageId: "<multi1>",
      raw: mimeWithParts("multi1", [{ mime: "image/jpeg", b64: IMG_B64 }, { mime: "image/png", b64: IMG_B64 }]),
    }, nowMs());
    expect(res.status).toBe("created");
    if (res.status !== "created") return;
    expect(res.count).toBe(2);
    expect(res.transactionIds).toHaveLength(2);
    const n = await env.DB.prepare("SELECT COUNT(*) AS c FROM transactions WHERE profile_id = ? AND source = 'email_in'")
      .bind(profileId).first<{ c: number }>();
    expect(n!.c).toBe(2);
  });

  it("accepts a PDF attachment and stores it as application/pdf", async () => {
    const { address } = await seedProfileWithInbox("business", "pro");
    const res = await inboundEmailLogic(emailEnv(), {
      to: address, from: "x@e.com", messageId: "<pdf1>",
      raw: mimeWithParts("pdf1", [{ mime: "application/pdf", b64: PDF_B64, filename: "invoice.pdf" }]),
    }, nowMs());
    expect(res.status).toBe("created");
    if (res.status !== "created") return;
    expect(res.count).toBe(1);
    const ct = await env.DB.prepare("SELECT content_type FROM receipt_images WHERE transaction_id = ?")
      .bind(res.transactionId).first<{ content_type: string }>();
    expect(ct!.content_type).toBe("application/pdf");
  });

  it("processes a mixed image + PDF email (both become receipts)", async () => {
    const { address } = await seedProfileWithInbox("business", "pro");
    const res = await inboundEmailLogic(emailEnv(), {
      to: address, from: "x@e.com", messageId: "<mix1>",
      raw: mimeWithParts("mix1", [{ mime: "image/jpeg", b64: IMG_B64 }, { mime: "application/pdf", b64: PDF_B64 }]),
    }, nowMs());
    expect(res.status).toBe("created");
    if (res.status !== "created") return;
    expect(res.count).toBe(2);
  });

  it("skips inline/embedded images and non-image/non-pdf attachments", async () => {
    const { address } = await seedProfileWithInbox("business", "pro");
    // inline logo + a real attached receipt + a CSV → only the receipt counts.
    const res = await inboundEmailLogic(emailEnv(), {
      to: address, from: "x@e.com", messageId: "<filter1>",
      raw: mimeWithParts("filter1", [
        { mime: "image/png", b64: IMG_B64, filename: "logo.png", disposition: "inline" },
        { mime: "text/csv", b64: IMG_B64, filename: "data.csv" },
        { mime: "image/jpeg", b64: IMG_B64, filename: "receipt.jpg" },
      ]),
    }, nowMs());
    expect(res.status).toBe("created");
    if (res.status !== "created") return;
    expect(res.count).toBe(1); // only the attached receipt
  });

  it("rejects an email whose only images are inline (no real receipt)", async () => {
    const { address } = await seedProfileWithInbox("business", "pro");
    const res = await inboundEmailLogic(emailEnv(), {
      to: address, from: "x@e.com", messageId: "<inlineonly>",
      raw: mimeWithParts("inlineonly", [{ mime: "image/png", b64: IMG_B64, disposition: "inline" }]),
    }, nowMs());
    expect(res).toEqual({ status: "rejected", reason: "no_image" });
  });

  it("caps the number of attachments processed per email", async () => {
    const { address } = await seedProfileWithInbox("business", "pro");
    const parts = Array.from({ length: 11 }, () => ({ mime: "image/jpeg", b64: IMG_B64 }));
    const res = await inboundEmailLogic(emailEnv(), {
      to: address, from: "x@e.com", messageId: "<capmany>", raw: mimeWithParts("capmany", parts),
    }, nowMs());
    expect(res.status).toBe("created");
    if (res.status !== "created") return;
    expect(res.count).toBe(8); // MAX_ATTACHMENTS
  });

  it("sends ONE summary push for a multi-attachment email", async () => {
    const { userId, address } = await seedProfileWithInbox("business", "pro");
    await seedDevice(userId);
    const spy = vi.spyOn(apns, "sendPush").mockResolvedValue({ stub: false, status: 200 });
    try {
      await inboundEmailLogic(emailEnv(), {
        to: address, from: "x@e.com", messageId: "<multipush>",
        raw: mimeWithParts("multipush", [{ mime: "image/jpeg", b64: IMG_B64 }, { mime: "image/jpeg", b64: IMG_B64 }]),
      }, nowMs());
      expect(spy).toHaveBeenCalledTimes(1); // one push to the one device, not one-per-receipt
      const p = spy.mock.calls[0]![2];
      expect(p.aps.alert.body).toBe("2 receipts arrived — tap to review.");
      expect(p.transactionId).toBeUndefined(); // summary → tap opens the list
    } finally {
      spy.mockRestore();
    }
  });
});
