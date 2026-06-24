// src/routes/extract.ts
import { Hono } from "hono";
import type { AppEnv } from "../env";
import { ApiError } from "../lib/errors";
import { uuidv7 } from "../lib/ids";
import { nowMs } from "../lib/time";
import { type ExtractedReceipt } from "../lib/deepseek";
import { runExtraction } from "../email/inbound";
import { currentPeriod, capForPlan, getUsage, incrementUsage } from "../lib/smartScan";

/**
 * POST /extract — auth (global middleware) + rate tier "extract" (mounted in app.ts).
 * Body is the raw receipt IMAGE bytes (image/jpeg or image/png); `source`, `capturedAt`, and
 * `requestId` ride as query params. The image goes STRAIGHT to Gemini vision — the SAME
 * extractor as email-in (`runExtraction`) — subject to the free/Pro monthly smart-scan cap.
 * Stub gate (E2E_EXTRACT_MODE or no GEMINI_API_KEY) → deterministic stub (no cap/no spend).
 * Over cap → a "needs review" draft (no AI). Always answers 200 with the §9 response shape.
 */
export const extractRoutes = new Hono<AppEnv>();

const MAX_IMAGE_BYTES = 6_291_456; // 6 MiB — mirrors images.ts / email-in

/** Today's date as YYYY-MM-DD (UTC) — the final date fallback. */
function todayIso(): string {
  return new Date().toISOString().slice(0, 10);
}

/** A "needs review" receipt (over cap / no AI) — the client shows Review with manual entry. */
function needsReviewReceipt(defaultDate: string): ExtractedReceipt {
  return {
    merchant: "", date: defaultDate, currencyCode: "AUD", total: 0, gst: null,
    category: "office", deductible: null, lineItems: [], confidence: 0, needsReview: true,
  };
}

extractRoutes.post("/", async (c) => {
  const startedAt = nowMs();
  const source = c.req.query("source") ?? "scan";
  const capturedAt = c.req.query("capturedAt") || undefined;
  const requestId = c.req.query("requestId") || uuidv7();
  const defaultDate = capturedAt ?? todayIso();
  const contentType = (c.req.header("content-type") ?? "image/jpeg").toLowerCase();

  const buf = await c.req.arrayBuffer();
  if (buf.byteLength === 0 || buf.byteLength > MAX_IMAGE_BYTES) {
    throw new ApiError("VALIDATION_FAILED", "A receipt image (≤6 MiB) is required in the body");
  }

  // Stub gate: deterministic stub when E2E or no Gemini key (hermetic tests) — no cap, no spend.
  const stubGate = c.env.E2E_EXTRACT_MODE === "1" || !c.env.GEMINI_API_KEY;

  let receipt: ExtractedReceipt;
  let model: string | null;
  let stub: boolean;
  let capped: boolean;
  let smartScan: { used: number; cap: number; plan: string } | undefined;

  if (stubGate) {
    const out = await runExtraction(c.env, buf, contentType, defaultDate);
    receipt = out.receipt;
    model = out.model;
    stub = true;
    capped = false;
    // smartScan intentionally omitted on the stub path.
  } else {
    const now = nowMs();
    const userId = c.var.userId;
    const userRow = await c.env.DB.prepare(
      "SELECT plan FROM users WHERE id = ? AND deleted_at IS NULL",
    ).bind(userId).first<{ plan: string }>();
    const plan = userRow?.plan ?? "free";
    const period = currentPeriod(now);
    const cap = capForPlan(plan, c.env);
    const used = await getUsage(c.env.DB, userId, period);

    if (used < cap) {
      // Under cap: Gemini vision (same as email-in). Count a slot only when it actually ran.
      stub = false;
      capped = false;
      model = c.env.GEMINI_MODEL ?? "gemini-3.1-flash-lite";
      try {
        const out = await runExtraction(c.env, buf, contentType, defaultDate);
        model = out.model;
        // Sanity gate (email-in parity): an empty/implausible result → "needs review".
        receipt = (out.usedLlm && out.receipt.total <= 0 && out.receipt.lineItems.length === 0)
          ? needsReviewReceipt(defaultDate)
          : out.receipt;
        if (out.usedLlm) {
          // TOCTOU: read-then-increment isn't atomic; the per-user extract rate limit bounds any
          // overage to at most 1, which is accepted (cheaper than a lock/serialised txn).
          await incrementUsage(c.env.DB, userId, period, nowMs());
          smartScan = { used: used + 1, cap, plan };
        } else {
          // Stub path inside runExtraction (no Gemini key) — don't burn a slot.
          smartScan = { used, cap, plan };
        }
      } catch (err) {
        // Gemini outage / parse failure → "needs review" draft, do NOT burn a slot (the user
        // got no AI result through no fault of their own). Mirrors the old DeepSeek fallback.
        console.error(
          "[extract] vision extraction failed",
          err instanceof Error ? `${err.name}: ${err.message}` : String(err),
        );
        receipt = needsReviewReceipt(defaultDate);
        smartScan = { used, cap, plan };
      }
    } else {
      // Over cap: a "needs review" draft, NO AI spend (client → manual entry + upgrade nudge).
      receipt = needsReviewReceipt(defaultDate);
      model = c.env.GEMINI_MODEL ?? "gemini-3.1-flash-lite";
      stub = false;
      capped = true;
      smartScan = { used, cap, plan };
    }
  }

  return c.json({
    requestId,
    receipt,
    meta: {
      model,
      source,
      latencyMs: nowMs() - startedAt,
      attempts: 0,
      stub,
      capped,
      ...(smartScan !== undefined ? { smartScan } : {}),
    },
  });
});
