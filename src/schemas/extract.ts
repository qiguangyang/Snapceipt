// src/schemas/extract.ts
import { z } from "zod";

/**
 * The 9 canonical category keys (spec §9). This array is the SINGLE source for:
 *  - the Zod enum below (validates DeepSeek output + the response), and
 *  - the verbatim list embedded in the DeepSeek system prompt (src/lib/deepseek.ts).
 * It deliberately EXCLUDES "custom" — the extractor never returns it.
 */
export const CATEGORY_KEYS = [
  "meals",
  "groceries",
  "fuel",
  "software",
  "office",
  "home",
  "health",
  "travel",
  "income",
] as const;

export type CategoryKey = (typeof CATEGORY_KEYS)[number];

const isoDate = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "expected YYYY-MM-DD");

/**
 * POST /extract request body. ocrText + source are required; the rest carry
 * server defaults so the 3-arg iOS client (ocrText, source, capturedAt) is valid.
 * requestId is echo-only (no server dedupe in v1).
 */
export const extractRequestSchema = z.object({
  ocrText: z.string().min(1, "ocrText is required").max(20000, "ocrText too long"),
  source: z.enum(["scan", "email_in"]),
  defaultCurrency: z.string().length(3).default("AUD"),
  locale: z.string().min(2).default("en-AU"),
  capturedAt: isoDate.optional(),
  requestId: z.string().min(1).max(200).optional(),
});

export type ExtractRequest = z.infer<typeof extractRequestSchema>;

/**
 * The shape DeepSeek is asked to emit (and what each retry attempt is validated
 * against). category MUST be one of the 9 keys; total >= 0; gst/deductible
 * nullable; confidence optional 0..1 (the server recomputes it regardless).
 */
export const deepseekReceiptSchema = z.object({
  merchant: z.string(),
  date: isoDate,
  currencyCode: z.string().length(3),
  total: z.number().nonnegative(),
  gst: z.number().nullable(),
  category: z.enum(CATEGORY_KEYS),
  // NOTE: `.int()` accepts integer-VALUED floats (50.0 passes, 33.3 is rejected).
  // The wire-level integer guarantee (no `50.0` token) is enforced in
  // deepseek.finalize() via Math.round, so the iOS Int? decode never throws.
  deductible: z.number().int().min(0).max(100).nullable(),
  lineItems: z
    .array(z.object({ name: z.string(), price: z.number() }))
    .default([]),
  confidence: z.number().min(0).max(1).optional(),
});

export type DeepseekReceipt = z.infer<typeof deepseekReceiptSchema>;
