// src/lib/deepseek.ts
import type { Env } from "../env";
import {
  deepseekReceiptSchema,
  type DeepseekReceipt,
} from "../schemas/extract";
import { heuristicExtract } from "./extractionHeuristic";

const DEEPSEEK_URL = "https://api.deepseek.com/chat/completions";
const TIMEOUT_MS = 20_000;
const MAX_ATTEMPTS = 3;

/** Per-category deductible defaults (spec §9), used to backfill when the model omits one. */
const DEDUCTIBLE_DEFAULTS: Record<string, number | null> = {
  meals: 50,
  groceries: 0,
  fuel: 100,
  software: 100,
  office: 100,
  home: 50,
  health: 0,
  travel: 100,
  income: null,
};

/**
 * VERBATIM system prompt. The 9-key list here MUST equal CATEGORY_KEYS
 * (src/schemas/extract.ts). Both prompts contain the word "json" (DeepSeek JSON
 * mode requires it).
 */
const SYSTEM_PROMPT = [
  "You extract structured data from noisy Australian receipt OCR text. Respond with ONLY a json object, no prose, no markdown fences:",
  '{ "merchant": string, "date": "YYYY-MM-DD", "currencyCode": "AUD", "total": number, "gst": number|null, "category": one of ["meals","groceries","fuel","software","office","home","health","travel","income"], "deductible": number 0-100|null, "lineItems": [{"name": string, "price": number}], "confidence": number 0-1 }',
  'Rules: AUD only. `category` MUST be exactly one of the nine keys above (no others). If GST isn\'t printed, set `gst` to total/11 rounded to cents. Set `deductible` to the per-category default unless the receipt clearly implies otherwise: meals 50, groceries 0, fuel 100, software 100, office 100, home 50, health 0, travel 100, income null. `total` is the GST-inclusive grand total as a positive number. Use `income` only for money received.',
].join("\n");

export interface ExtractionInput {
  ocrText: string;
  source: "scan" | "email_in";
  defaultDate: string; // capturedAt or today, used for the date fallback
}

/** The §9 receipt half (server-finalized). */
export interface ExtractedReceipt {
  merchant: string;
  date: string;
  currencyCode: string;
  total: number;
  gst: number | null;
  category: string;
  deductible: number | null;
  lineItems: { name: string; price: number }[];
  confidence: number;
  needsReview: boolean;
}

export interface DeepseekResult {
  receipt: ExtractedReceipt;
  meta: { model: string; attempts: number; stub: false };
}

function clamp01(n: number): number {
  return Math.max(0, Math.min(1, n));
}
function roundCents(n: number): number {
  return Math.round(n * 100) / 100;
}

/** Heuristic OCR-quality score from length + line structure (0..1). */
function ocrQuality(ocrText: string): number {
  const len = ocrText.trim().length;
  const lines = ocrText.split(/\r?\n/).filter((l) => l.trim().length > 0).length;
  const lenScore = clamp01(len / 200); // ~200 chars reads as a full receipt
  const lineScore = clamp01(lines / 6); // ~6 lines reads as structured
  return clamp01(0.5 * lenScore + 0.5 * lineScore);
}

/** arithmeticConsistency: 1 when line items sum within 5% of total, else 0.5. */
function arithmeticConsistency(lineItems: { price: number }[], total: number): number {
  if (lineItems.length === 0 || total <= 0) return 0.5;
  const sum = lineItems.reduce((acc, li) => acc + li.price, 0);
  const diff = Math.abs(sum - total);
  return diff <= total * 0.05 ? 1 : 0.5;
}

/** Try to coerce a model string into a validated DeepseekReceipt; null on failure. */
function tryParseReceipt(content: string): DeepseekReceipt | null {
  // (a) direct parse
  let obj: unknown;
  try {
    obj = JSON.parse(content);
  } catch {
    // (b) strip ``` fences / extract the first {...}
    const fenceless = content.replace(/```(?:json)?/gi, "").replace(/```/g, "");
    const match = fenceless.match(/\{[\s\S]*\}/);
    if (!match) return null;
    try {
      obj = JSON.parse(match[0]);
    } catch {
      return null;
    }
  }
  const parsed = deepseekReceiptSchema.safeParse(obj);
  return parsed.success ? parsed.data : null;
}

/** One DeepSeek call with a 20s abort budget. Returns the message content, or null on any failure. */
async function callDeepseek(
  env: Env,
  model: string,
  messages: { role: string; content: string }[],
): Promise<string | null> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    const res = await fetch(DEEPSEEK_URL, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.DEEPSEEK_API_KEY}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        model,
        response_format: { type: "json_object" },
        temperature: 0,
        max_tokens: 1500,
        messages,
      }),
      signal: controller.signal,
    });
    if (!res.ok) return null;
    const json = (await res.json()) as { choices?: { message?: { content?: string } }[] };
    return json.choices?.[0]?.message?.content ?? null;
  } catch {
    // AbortError (timeout) / network error -> treat as a failed attempt.
    return null;
  } finally {
    clearTimeout(timer);
  }
}

/** Finalize a validated DeepSeek receipt: backfill deductible, infer GST, compute confidence. */
function finalize(input: ExtractionInput, r: DeepseekReceipt): ExtractedReceipt {
  const total = roundCents(Math.max(0, r.total));

  // GST non-null guarantee: infer round(total/11) when absent and total>0; null only at total==0.
  let gst = r.gst;
  if (total === 0) gst = null;
  else if (gst === null || gst === undefined) gst = roundCents(total / 11);
  else gst = roundCents(gst);

  // Deductible backfill from the per-category default when the model omitted it,
  // then coerce to an INTEGER literal so the wire never emits a float like 50.0
  // (the iOS decodeIfPresent(Int.self) would throw on a 50.0 JSON token).
  const deductibleRaw =
    r.deductible ?? (r.category in DEDUCTIBLE_DEFAULTS ? DEDUCTIBLE_DEFAULTS[r.category] : null);
  const deductible = deductibleRaw == null ? null : Math.round(deductibleRaw);

  const modelStated = r.confidence ?? 0.7;
  const confidence = clamp01(
    0.55 * modelStated +
      0.25 * ocrQuality(input.ocrText) +
      0.2 * arithmeticConsistency(r.lineItems, total),
  );

  return {
    merchant: r.merchant,
    date: r.date,
    currencyCode: "AUD",
    total,
    gst,
    category: r.category,
    deductible,
    lineItems: r.lineItems.map((li) => ({ name: li.name, price: roundCents(li.price) })),
    confidence,
    needsReview: confidence < 0.8,
  };
}

/** The deterministic fallback at the end of the ladder: heuristic + needsReview + low confidence. */
export function fallback(input: ExtractionInput): ExtractedReceipt {
  const h = heuristicExtract(input.ocrText, input.defaultDate);
  return {
    merchant: h.merchant,
    date: h.date,
    currencyCode: "AUD",
    total: h.total,
    gst: h.total === 0 ? null : h.gst,
    category: h.category,
    deductible: h.deductible,
    lineItems: h.lineItems,
    confidence: 0.4,
    needsReview: true,
  };
}

/**
 * Run the real DeepSeek extraction with the <=3-attempt validate/retry ladder.
 * Attempt 1: base prompt. Attempt 2: corrective re-prompt with the prior raw
 * output ("return valid json"). Attempt 3: same corrective prompt — tryParseReceipt
 * already strips fences / extracts the first {...} on every attempt. On exhaustion,
 * the deterministic heuristic fallback (needsReview:true).
 */
export async function runDeepseekExtraction(env: Env, input: ExtractionInput): Promise<DeepseekResult> {
  // deepseek-chat deprecates 2026-07-24; default is now deepseek-v4-flash.
  // deepseek-v4-flash pricing: $0.14/M in (cache miss), $0.0028/M in (cache hit), $0.28/M out.
  const model = env.DEEPSEEK_MODEL ?? "deepseek-v4-flash";
  const userPrompt = `Extract the receipt as json. OCR text:\n${input.ocrText}`;

  let attempts = 0;
  let lastRaw = "";

  while (attempts < MAX_ATTEMPTS) {
    attempts += 1;
    const messages =
      attempts === 1
        ? [
            { role: "system", content: SYSTEM_PROMPT },
            { role: "user", content: userPrompt },
          ]
        : [
            { role: "system", content: SYSTEM_PROMPT },
            { role: "user", content: userPrompt },
            { role: "assistant", content: lastRaw },
            {
              role: "user",
              content:
                "That was not valid against the schema. Return ONLY a valid json object matching the schema, no prose, no markdown fences.",
            },
          ];

    const content = await callDeepseek(env, model, messages);
    if (content !== null) {
      lastRaw = content;
      const parsed = tryParseReceipt(content);
      if (parsed) {
        return { receipt: finalize(input, parsed), meta: { model, attempts, stub: false } };
      }
    }
  }

  return { receipt: fallback(input), meta: { model, attempts, stub: false } };
}
