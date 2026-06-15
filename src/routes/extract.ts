// src/routes/extract.ts
import { Hono } from "hono";
import type { AppEnv } from "../env";
import { uuidv7 } from "../lib/ids";
import { nowMs } from "../lib/time";
import { validate } from "./auth";
import { extractRequestSchema } from "../schemas/extract";
import { heuristicExtract } from "../lib/extractionHeuristic";
import { runDeepseekExtraction, fallback, type ExtractedReceipt } from "../lib/deepseek";
import {
  currentPeriod,
  capForPlan,
  getUsage,
  incrementUsage,
} from "../lib/smartScan";

/**
 * POST /extract — auth (global middleware) + rate tier "extract" (mounted in
 * app.ts). Validates the body, resolves the fallback date (capturedAt ?? today),
 * and either returns a deterministic stub (when E2E_EXTRACT_MODE === "1" OR no
 * DEEPSEEK_API_KEY) or runs the real DeepSeek extraction subject to the
 * free/Pro smart-scan monthly cap. Always answers 200 with the §9 response
 * (needsReview may be true — the client still shows Review).
 */
export const extractRoutes = new Hono<AppEnv>();

/** Today's date as YYYY-MM-DD (UTC) — the final date fallback. */
function todayIso(): string {
  return new Date().toISOString().slice(0, 10);
}

/** The deterministic stub: the same heuristic as the fallback, but confident. */
function stubReceipt(ocrText: string, defaultDate: string): ExtractedReceipt {
  const h = heuristicExtract(ocrText, defaultDate);
  return {
    merchant: h.merchant,
    date: h.date,
    currencyCode: "AUD",
    total: h.total,
    gst: h.total === 0 ? null : h.gst,
    category: h.category,
    deductible: h.deductible,
    lineItems: h.lineItems,
    confidence: 0.9,
    needsReview: false,
  };
}

extractRoutes.post("/", validate("json", extractRequestSchema), async (c) => {
  const body = c.req.valid("json");
  const startedAt = nowMs();
  const defaultDate = body.capturedAt ?? todayIso();
  const requestId = body.requestId ?? uuidv7();

  // stubGate: E2E_EXTRACT_MODE or no DEEPSEEK_API_KEY → deterministic stub,
  // no cap check, no incrementing.
  const stubGate = c.env.E2E_EXTRACT_MODE === "1" || !c.env.DEEPSEEK_API_KEY;

  let receipt: ExtractedReceipt;
  let model: string;
  let attempts: number;
  let stub: boolean;
  let capped: boolean;
  let smartScan: { used: number; cap: number; plan: string } | undefined;

  if (stubGate) {
    receipt = stubReceipt(body.ocrText, defaultDate);
    model = c.env.DEEPSEEK_MODEL ?? "deepseek-v4-flash";
    attempts = 0;
    stub = true;
    capped = false;
    // smartScan is intentionally omitted on the stub path.
  } else {
    const now = nowMs();
    const userId = c.var.userId;

    // 1. Read plan (mirrors plan.ts SELECT pattern).
    const userRow = await c.env.DB.prepare(
      "SELECT plan FROM users WHERE id = ? AND deleted_at IS NULL",
    )
      .bind(userId)
      .first<{ plan: string }>();
    const plan = userRow?.plan ?? "free";

    // 2. Compute period + cap + current usage.
    const period = currentPeriod(now);
    const cap = capForPlan(plan, c.env);
    const used = await getUsage(c.env.DB, userId, period);

    if (used < cap) {
      // 3a. Under cap: run DeepSeek (real LLM), then count the slot.
      const result = await runDeepseekExtraction(c.env, {
        ocrText: body.ocrText,
        source: body.source,
        defaultDate,
      });
      receipt = result.receipt;
      model = result.meta.model;
      attempts = result.meta.attempts;
      stub = false;
      capped = false;
      if (result.meta.usedLlm) {
        // LLM produced a parseable answer — consume one smart-scan slot.
        // NOTE: TOCTOU race — this read-then-increment is NOT atomic. Two concurrent
        // under-cap requests for the same user can both pass the `used < cap` check
        // and both proceed, briefly exceeding the cap by at most 1. This is accepted:
        // the per-user extract rate limit bounds the overage, and a lock / serialised
        // transaction is not worth the latency cost for this use case.
        await incrementUsage(c.env.DB, userId, period, nowMs());
        smartScan = { used: used + 1, cap, plan };
      } else {
        // DeepSeek exhausted all attempts and fell back to heuristic (e.g. outage).
        // Do NOT burn a slot — the user got a heuristic result through no fault of
        // their own; meta.capped stays false so the client knows the slot was free.
        smartScan = { used, cap, plan };
      }
    } else {
      // 3b. Cap exhausted: serve heuristic, do NOT call DeepSeek.
      // Use the heuristic's own category/confidence/needsReview (graded 0.30–0.75).
      const h = heuristicExtract(body.ocrText, defaultDate);
      receipt = {
        merchant: h.merchant,
        date: h.date,
        currencyCode: "AUD",
        total: h.total,
        gst: h.total === 0 ? null : h.gst,
        category: h.category,
        deductible: h.deductible,
        lineItems: h.lineItems,
        confidence: h.confidence,
        needsReview: h.needsReview,
      };
      model = c.env.DEEPSEEK_MODEL ?? "deepseek-v4-flash";
      attempts = 0;
      stub = false;
      capped = true;
      // Do NOT increment — the cap is already hit.
      smartScan = { used, cap, plan };
    }
  }

  return c.json({
    requestId,
    receipt,
    meta: {
      model,
      source: body.source,
      latencyMs: nowMs() - startedAt,
      attempts,
      stub,
      capped,
      ...(smartScan !== undefined ? { smartScan } : {}),
    },
  });
});
