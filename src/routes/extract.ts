// src/routes/extract.ts
import { Hono } from "hono";
import type { AppEnv } from "../env";
import { uuidv7 } from "../lib/ids";
import { nowMs } from "../lib/time";
import { validate } from "./auth";
import { extractRequestSchema } from "../schemas/extract";
import { heuristicExtract } from "../lib/extractionHeuristic";
import { runDeepseekExtraction, type ExtractedReceipt } from "../lib/deepseek";

/**
 * POST /extract — auth (global middleware) + rate tier "extract" (mounted in
 * app.ts). Validates the body, resolves the fallback date (capturedAt ?? today),
 * and either returns a deterministic stub (when E2E_EXTRACT_MODE === "1" OR no
 * DEEPSEEK_API_KEY) or runs the real DeepSeek extraction. Always answers 200 with
 * the §9 response (needsReview may be true — the client still shows Review).
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

  const stubGate = c.env.E2E_EXTRACT_MODE === "1" || !c.env.DEEPSEEK_API_KEY;

  let receipt: ExtractedReceipt;
  let model: string;
  let attempts: number;
  let stub: boolean;

  if (stubGate) {
    receipt = stubReceipt(body.ocrText, defaultDate);
    model = c.env.DEEPSEEK_MODEL ?? "deepseek-chat";
    attempts = 0;
    stub = true;
  } else {
    const result = await runDeepseekExtraction(c.env, {
      ocrText: body.ocrText,
      source: body.source,
      defaultDate,
    });
    receipt = result.receipt;
    model = result.meta.model;
    attempts = result.meta.attempts;
    stub = false;
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
    },
  });
});
