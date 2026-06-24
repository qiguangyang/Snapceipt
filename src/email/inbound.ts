// src/email/inbound.ts
import PostalMime from "postal-mime";
import type { Env } from "../env";
import { uuidv7 } from "../lib/ids";
import { resolveInboxToken, tokenFromRecipient, type InboxOwner } from "../lib/inboxToken";
import { STUB_OCR_TEXT } from "../lib/ocr";
import { heuristicExtract } from "../lib/extractionHeuristic";
import { runGeminiVisionExtraction, type ExtractedReceipt } from "../lib/deepseek";
import { isProUser } from "../lib/plan";
import { writeReceiptRows } from "../lib/receiptRows";
import { capForPlan, currentPeriod, getUsage, incrementUsage } from "../lib/smartScan";
import { notifyEmailInReceipt } from "./notify";

const MAX_IMAGE_BYTES = 6_291_456; // 6 MiB — mirrors images.ts
/** Max inbound emails accepted per inbox alias per hour (coarse flood throttle). */
const INBOUND_RATE_LIMIT = 20;
const INBOUND_WINDOW_MS = 60 * 60 * 1000;

/** Fixed-window KV counter per inbox token. Returns true when the alias is over its
 *  hourly limit (so the email() wrapper can bounce it) — bounds Gemini extraction
 *  spend from a flood against a single (possibly leaked) alias. */
async function overInboundRateLimit(kv: KVNamespace, token: string, now: number): Promise<boolean> {
  const bucket = Math.floor(now / INBOUND_WINDOW_MS);
  const key = `rl:inbound:${token}:${bucket}`;
  const current = Number((await kv.get(key)) ?? "0");
  if (current >= INBOUND_RATE_LIMIT) return true;
  await kv.put(key, String(current + 1), { expirationTtl: Math.ceil(INBOUND_WINDOW_MS / 1000) + 60 });
  return false;
}

/** The shape the email() wrapper hands to the pure core. */
export interface InboundMessage {
  to: string;
  from: string;
  messageId: string | null;
  raw: ReadableStream<Uint8Array> | ArrayBuffer | Uint8Array | string;
}

export type InboundResult =
  | { status: "rejected"; reason: "unknown_inbox" | "no_image" | "rate_limited" | "pro_only" }
  | { status: "duplicate" }
  | { status: "created"; transactionId: string; extraction: "done" | "failed" };

function todayIso(now: number): string {
  return new Date(now).toISOString().slice(0, 10);
}
function isImage(mimeType: string | undefined | null): boolean {
  return typeof mimeType === "string" && mimeType.toLowerCase().startsWith("image/");
}
function toArrayBuffer(content: ArrayBuffer | Uint8Array | string): ArrayBuffer {
  if (content instanceof ArrayBuffer) return content;
  if (content instanceof Uint8Array) {
    return content.buffer.slice(content.byteOffset, content.byteOffset + content.byteLength) as ArrayBuffer;
  }
  return new TextEncoder().encode(content).buffer as ArrayBuffer; // base64/text fallback
}
function failedReceipt(date: string): ExtractedReceipt {
  return {
    merchant: "", date, currencyCode: "AUD", total: 0, gst: null,
    category: "office", deductible: null, lineItems: [], confidence: 0, needsReview: true,
  };
}

/** Extraction with the same stub gate as POST /extract. The image goes DIRECTLY to the
 *  multimodal Gemini model in one call (no Workers-AI OCR step). `usedLlm` mirrors the
 *  /extract contract: true only when Gemini produced a parseable answer, so the caller
 *  charges a smart-scan slot only then.
 *
 *  Stub gate (E2E_EXTRACT_MODE or no key): returns the SAME deterministic heuristic stub as
 *  before (over STUB_OCR_TEXT) so the suite stays hermetic — no image bytes are read. */
async function runExtraction(
  env: Env,
  imageBytes: ArrayBuffer,
  contentType: string,
  defaultDate: string,
): Promise<{ receipt: ExtractedReceipt; model: string; usedLlm: boolean }> {
  const stubGate = env.E2E_EXTRACT_MODE === "1" || !env.GEMINI_API_KEY;
  if (stubGate) {
    const h = heuristicExtract(STUB_OCR_TEXT, defaultDate);
    return {
      receipt: {
        merchant: h.merchant, date: h.date, currencyCode: "AUD", total: h.total,
        gst: h.total === 0 ? null : h.gst, category: h.category, deductible: h.deductible,
        lineItems: h.lineItems, confidence: 0.9, needsReview: false,
      },
      model: env.GEMINI_MODEL ?? "gemini-3.1-flash-lite",
      usedLlm: false,
    };
  }
  const result = await runGeminiVisionExtraction(env, imageBytes, contentType, defaultDate);
  return { receipt: result.receipt, model: result.meta.model, usedLlm: result.meta.usedLlm };
}

async function logInbound(
  db: D1Database,
  messageId: string,
  owner: InboxOwner | null,
  txnId: string | null,
  status: "created" | "failed" | "rejected",
  reason: string | null,
  now: number,
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO inbound_email_log (message_id, user_id, profile_id, transaction_id, status, reason, received_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
    )
    .bind(messageId, owner?.userId ?? null, owner?.profileId ?? null, txnId, status, reason, now)
    .run();
}

/**
 * Pure inbound core (the email() handler is not invocable in vitest-pool-workers).
 * Resolve alias -> Pro gate -> dedup -> parse -> store image -> vision extract (gated, image
 * direct to Gemini) -> write rows. Extraction failure still creates a 'failed'
 * transaction so the receipt is never lost. The inbound_email_log row is written only
 * on a terminal outcome, so a mid-flight crash safely reprocesses on redelivery.
 */
export async function inboundEmailLogic(env: Env, msg: InboundMessage, now: number): Promise<InboundResult> {
  // 1. Resolve the alias -> owner.
  const token = tokenFromRecipient(msg.to);
  if (!token) return { status: "rejected", reason: "unknown_inbox" };
  const owner = await resolveInboxToken(env.DB, token);
  if (!owner) return { status: "rejected", reason: "unknown_inbox" };

  // 1b. Pro gate: email-in is a Pro-only feature. Bounce a free owner BEFORE any
  // dedup/image/R2/AI work so a free user's mail has ZERO side effects (no stored image,
  // no inbound_email_log row, no extraction spend). Server-side enforcement so a modified
  // client can't bypass payment. The email() wrapper turns this into a sender bounce.
  if (!(await isProUser(env.DB, owner.userId))) {
    return { status: "rejected", reason: "pro_only" };
  }

  // 2. Dedup on Message-ID (synthesize one when absent so the row is still logged).
  const messageId = msg.messageId && msg.messageId.length > 0 ? msg.messageId : `no-id:${uuidv7()}`;
  const dup = await env.DB.prepare("SELECT 1 FROM inbound_email_log WHERE message_id = ?").bind(messageId).first();
  if (dup) return { status: "duplicate" };

  // 2b. Coarse per-alias rate limit (after dedup so redeliveries don't count). Bounds
  // Gemini spend from a flood against a (possibly leaked) alias; the email()
  // wrapper bounces the over-limit message.
  if (await overInboundRateLimit(env.KV, token, now)) {
    await logInbound(env.DB, messageId, owner, null, "rejected", "rate_limited", now);
    return { status: "rejected", reason: "rate_limited" };
  }

  // 3. Parse MIME; pick the first image attachment under the size cap.
  const parsed = await new PostalMime().parse(msg.raw);
  const image = (parsed.attachments ?? []).find((att) => isImage(att.mimeType));
  if (!image) {
    await logInbound(env.DB, messageId, owner, null, "rejected", "no_image", now);
    return { status: "rejected", reason: "no_image" };
  }
  const buf = toArrayBuffer(image.content as ArrayBuffer | Uint8Array | string);
  if (buf.byteLength === 0 || buf.byteLength > MAX_IMAGE_BYTES) {
    await logInbound(env.DB, messageId, owner, null, "rejected", "no_image", now);
    return { status: "rejected", reason: "no_image" };
  }
  const contentType = (image.mimeType ?? "image/jpeg").toLowerCase();
  const ext = contentType.includes("png") ? "png" : "jpg";

  // 4. Store the image to R2 under the owner's prefix.
  const r2Key = `u/${owner.userId}/${uuidv7()}.${ext}`;
  await env.RECEIPTS.put(r2Key, buf, { httpMetadata: { contentType } });

  // 5. Profile type drives txn.mode.
  const prof = await env.DB.prepare("SELECT type FROM profiles WHERE id = ?").bind(owner.profileId).first<{ type: string }>();
  const profileType = prof?.type ?? "personal";
  const defaultDate = todayIso(now);

  // 6. Cap gate: email-in extractions count against the SAME monthly smart-scan budget
  // as POST /extract, checked BEFORE the expensive Gemini vision call. Over
  // cap → store the image + a needs-review transaction (never lose the receipt) with no AI
  // spend, so a free user can't mail their alias for unlimited extractions.
  const period = currentPeriod(now);
  const planRow = await env.DB.prepare("SELECT plan FROM users WHERE id = ?")
    .bind(owner.userId)
    .first<{ plan: string }>();
  const cap = capForPlan(planRow?.plan, env);
  const overCap = (await getUsage(env.DB, owner.userId, period)) >= cap;

  // No OCR step anymore: the image goes straight to the multimodal model. ocrText is null.
  const ocrText: string | null = null;
  let receipt: ExtractedReceipt;
  let extraction: "done" | "failed" = "done";
  let model: string | null = null;
  let chargeSlot = false;
  if (overCap) {
    extraction = "failed";
    receipt = failedReceipt(defaultDate);
  } else {
    // Vision extraction (gated). Any failure => failed transaction, image kept.
    try {
      const out = await runExtraction(env, buf, contentType, defaultDate);
      receipt = out.receipt;
      model = out.model;
      // Charge a slot only when DeepSeek actually ran (parity with /extract).
      chargeSlot = out.usedLlm;
      // Sanity gate (real extractions only — the stub returns a populated receipt): an empty /
      // implausible result (no total AND no line items) is honestly marked "failed" so the
      // image is kept for review instead of persisting a misleading zeros receipt.
      if (chargeSlot && receipt.total <= 0 && receipt.lineItems.length === 0) {
        extraction = "failed";
        receipt = failedReceipt(defaultDate);
      }
    } catch (err) {
      // Surface the failure (it was silently swallowed): the error from the vision call.
      console.error(
        "[email-in] vision extraction failed",
        err instanceof Error ? `${err.name}: ${err.message}` : String(err),
        err instanceof Error ? (err.stack ?? "") : "",
      );
      extraction = "failed";
      receipt = failedReceipt(defaultDate);
    }
  }
  // Increment usage OUTSIDE the extraction try so a transient counter-write failure can't
  // discard an otherwise-good extraction. Best-effort: under-counting one slot is harmless.
  if (chargeSlot) {
    try { await incrementUsage(env.DB, owner.userId, period, now); } catch { /* best-effort */ }
  }

  // 7. Write rows.
  const transactionId = await writeReceiptRows(env.DB, {
    userId: owner.userId, profileId: owner.profileId, profileType,
    receipt, ocrText, r2Key, contentType, byteSize: buf.byteLength,
    extractionStatus: extraction, extractionModel: model, nowMs: now,
  });

  await logInbound(
    env.DB, messageId, owner, transactionId,
    extraction === "done" ? "created" : "failed",
    overCap ? "over_cap" : null, now,
  );
  await notifyEmailInReceipt(env, owner.userId, transactionId, receipt.merchant, extraction, now);
  return { status: "created", transactionId, extraction };
}
