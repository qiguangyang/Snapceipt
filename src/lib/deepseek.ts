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
  'Rules: AUD only. `category` MUST be exactly one of the nine keys above (no others). Set `deductible` to the per-category default unless the receipt clearly implies otherwise: meals 50, groceries 0, fuel 100, software 100, office 100, home 50, health 0, travel 100, income null. `total` is the GST-inclusive grand total as a positive number. Use `income` only for money received.',
  'GST: if a GST/tax amount is printed (e.g. "TOTAL includes GST $1.64"), use that EXACT printed value for `gst`. Only if no GST amount is printed, set `gst` to total/11 rounded to cents. Australian receipts are often largely GST-free (fresh food) — never overwrite a printed GST with total/11.',
  '`lineItems` are ONLY actually-purchased products. EXCLUDE: payment/card/EFTPOS/balance/change/approval blocks; loyalty/rewards/points/credits; store/ABN/legal/contact/terminal details; barcodes; savings or "you saved" lines; subtotals and totals; and promotional/advertising/coupon offers (e.g. "BUY ANY 2 WINES", BWS beer/wine specials, "PRESENT YOUR COUPON"). A product name and its price may be on SEPARATE lines (e.g. "Kiwifruit Gold New Zealand" then "0.977 kg NET @ $10.90/kg 10.65") — pair them so `name` is the PRODUCT (\"Kiwifruit Gold New Zealand\"), not the weight/qty line. Each `price` is the line\'s RIGHTMOST dollar amount = the line total (10.65), NEVER a per-unit price ("$10.90/kg", "$2.50 each") and NEVER a size/weight token ("130g", "750ml", "1kg") — those are not prices.',
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
  meta: { model: string; attempts: number; stub: false; usedLlm: boolean };
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

/** Largest amount on a line that contains the word "GST" (e.g. "TOTAL includes GST $1.64"
 * → 1.64); null when no GST line carries an amount. Deterministic — the LLM sometimes grabs
 * an ABN ("TAX INVOICE - ABN 88 000 014 675") or a payment figure as GST. */
function printedGst(ocrText: string): number | null {
  let found: number | null = null;
  for (const line of ocrText.split(/\r?\n/)) {
    if (!/\bgst\b/i.test(line)) continue;
    const amounts = [...line.matchAll(/(\d{1,3}(?:[ ,]\d{3})*\.\d{2})/g)].map((m) =>
      parseFloat(m[1].replace(/[ ,]/g, "")),
    );
    if (amounts.length) found = amounts[amounts.length - 1];
  }
  return found;
}

/** GST on a GST-inclusive total can never exceed total/11. Prefer a printed "GST $X" line;
 * otherwise clamp an impossible model value down to the cap. */
export function reconcileGst(gst: number | null, total: number, ocrText: string): number | null {
  if (total <= 0) return null;
  const cap = roundCents(total / 11);
  const printed = printedGst(ocrText);
  if (printed != null && printed >= 0 && printed <= cap + 0.005) return roundCents(printed);
  if (gst != null && gst > cap + 0.005) return cap;
  return gst;
}

/** Trim everything after the grand total — the payment block (card, terminal, redemption…),
 * rewards, and marketing/coupons — so the extractor only sees real purchased items. Cuts at
 * the first divider or known footer/payment marker AFTER the grand-total line, so item lines
 * are never lost. GST is read from the FULL text in reconcileGst, and the merchant from
 * detectMerchant, so dropping those tail sections here is safe. */
export function trimReceiptTail(text: string): string {
  const lines = text.split(/\r?\n/);
  let totalIdx = -1;
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i].toLowerCase();
    if (/\btotal\b/.test(l) && !/sub ?total/.test(l)) {
      totalIdx = i;
      break;
    }
  }
  if (totalIdx < 0) return text;
  const footer =
    /^\s*[-=_*]{8,}\s*$|merch id|term id|\bcard\s*:|approved|redemption|cookware|everyday extra|thank you|present your coupon|buy any \d|\bbws\b|rewards points|you (just )?collected|t&cs?\b/i;
  for (let i = totalIdx + 1; i < lines.length; i++) {
    if (footer.test(lines[i])) return lines.slice(0, i).join("\n");
  }
  return text;
}

/** Canonical AU retailer name when one is mentioned anywhere in the receipt — receipts often
 * print the brand only in the (now-trimmed) payment/footer block, so the model picks the
 * street address instead. Returns null when no known brand is present (keep the model's). */
const KNOWN_MERCHANTS = [
  "Woolworths", "Coles", "ALDI", "BWS", "Dan Murphy's", "Bunnings", "Kmart", "Target",
  "Big W", "Officeworks", "Chemist Warehouse", "Priceline", "JB Hi-Fi", "Harvey Norman",
  "7-Eleven", "Costco", "Myer", "David Jones", "Rebel", "Supercheap Auto", "Petbarn",
  "IGA", "Ampol", "Caltex", "McDonald's", "KFC", "Subway", "Guzman y Gomez",
];
export function detectMerchant(ocrText: string): string | null {
  const lower = ocrText.toLowerCase();
  for (const m of KNOWN_MERCHANTS) {
    if (lower.includes(m.toLowerCase())) return m;
  }
  return null;
}

/** The transaction date (YYYY-MM-DD) from the FULL receipt text — the trimmed item section
 * usually has no date; it's in the payment block / footer ("21/03/26 17:21", "… 21/03/2026"),
 * so the model defaults to "today". AU is day-first. Prefer a date printed next to a TIME (the
 * transaction timestamp); skip promo/offer EXPIRY dates ("BEER OFFERS EXPIRE: 09.06.2026").
 * null when nothing parseable, so the caller keeps the model's date. */
export function detectDate(ocrText: string): string | null {
  const dateRe = /\b(\d{1,2})[\/.\-](\d{1,2})[\/.\-](\d{2,4})\b/;
  const timeRe = /\b\d{1,2}:\d{2}\b/;
  const withTime: string[] = [];
  const others: string[] = [];
  for (const line of ocrText.split(/\r?\n/)) {
    if (/expire|expiry|valid|offer|redeem|t&c|use by|best before/i.test(line)) continue;
    const m = line.match(dateRe);
    if (!m) continue;
    let day = parseInt(m[1], 10);
    let month = parseInt(m[2], 10);
    let year = parseInt(m[3], 10);
    if (day <= 12 && month > 12) [day, month] = [month, day]; // tolerate MM/DD
    if (month < 1 || month > 12 || day < 1 || day > 31) continue;
    if (year < 100) year += 2000;
    if (year < 2000 || year > 2100) continue;
    const ymd = `${year}-${String(month).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
    (timeRe.test(line) ? withTime : others).push(ymd);
  }
  return withTime[0] ?? others[0] ?? null;
}

/** A lineItem that is really payment/total/savings noise (e.g. "REDEMPTION", "Change",
 * "You saved $107.00", a barcode). Conservative — real product names don't match. */
function isNoiseItem(name: string): boolean {
  const n = name.trim();
  if (n.length < 2) return true;
  if (/^\d[\d ]{7,}$/.test(n)) return true; // barcode / id digits
  if (/^[a-z]?-?\d{3,}\b/i.test(n)) return true; // terminal/card refs like "X-2834"
  return /\b(sub ?total|total|eftpos|balance|change|approved|redemption|merch|term id|card|tendered|rounding|you saved|present your|coupon|t&cs?)\b/i.test(
    n,
  );
}

/** Deterministically parse line items from a structured receipt: a product-name line
 * followed by a detail line ("0.977 kg NET @ $10.90/kg 10.65", "Qty 2 @ $7.50 each 15.00")
 * pairs into name = the product, price = the line's LAST amount (the line total). Simple
 * "Name 4.50" lines are taken directly. The cheap LLM mis-pairs these (name = the weight
 * line, price = the /kg unit price), so this is used to override it when reliable. */
export function parseStructuredLineItems(text: string): { name: string; price: number }[] {
  const amountRe = /(-?\d{1,3}(?:[, ]\d{3})*\.\d{2})/g;
  const detailRe = /\bkg\b.*@|@\s*\$?\d|\bqty\s+\d|\beach\b|\/kg/i;
  const noiseRe =
    /\b(sub ?total|total|gst|abn|tax invoice|eftpos|balance|change|approved|redemption|merch|term id|card|you saved|promotional|count of items|rounding|description)\b/i;
  const lastAmount = (s: string): number | null => {
    const m = [...s.matchAll(amountRe)];
    return m.length ? parseFloat(m[m.length - 1][1].replace(/[, ]/g, "")) : null;
  };
  const strip = (s: string): string =>
    s
      .replace(/^[\^#*\s]+/, "")
      .replace(/\s*\$?-?\d{1,3}(?:[, ]\d{3})*\.\d{2}\s*$/, "")
      .trim();
  const items: { name: string; price: number }[] = [];
  let pendingName: string | null = null;
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line) continue;
    if (noiseRe.test(line)) {
      pendingName = null;
      continue;
    }
    const amt = lastAmount(line);
    if (amt == null) {
      const n = strip(line);
      pendingName = n.length >= 2 ? n : null;
      continue;
    }
    const name = detailRe.test(line) ? pendingName ?? strip(line) : strip(line);
    if (name.length >= 2) items.push({ name, price: amt });
    pendingName = null;
  }
  return items;
}

/** Prefer the deterministic parse over the model's line items ONLY when it's clearly right:
 * the parsed prices sum to the receipt total (within tolerance). Otherwise keep the model's
 * (better for unstructured / photographed receipts). */
function reconcileLineItems(
  modelItems: { name: string; price: number }[],
  text: string,
  total: number,
): { name: string; price: number }[] {
  if (total <= 0) return modelItems;
  const det = parseStructuredLineItems(text);
  if (det.length >= 3) {
    const sum = det.reduce((a, i) => a + i.price, 0);
    if (Math.abs(sum - total) <= Math.max(1, total * 0.05)) {
      return det.map((i) => ({ name: i.name, price: roundCents(i.price) }));
    }
  }
  return modelItems;
}

/** Finalize a validated DeepSeek receipt: backfill deductible, infer GST, compute confidence. */
function finalize(input: ExtractionInput, r: DeepseekReceipt): ExtractedReceipt {
  const total = roundCents(Math.max(0, r.total));

  // GST non-null guarantee: infer round(total/11) when absent and total>0; null only at total==0.
  let gst = r.gst;
  if (total === 0) gst = null;
  else if (gst === null || gst === undefined) gst = roundCents(total / 11);
  else gst = roundCents(gst);
  // Deterministic guard: trust a printed "GST $X" line over the model, and never let GST
  // exceed total/11 (catches the model grabbing an ABN/payment figure, e.g. "$88").
  gst = reconcileGst(gst, total, input.ocrText);

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
    merchant: detectMerchant(input.ocrText) ?? r.merchant,
    date: detectDate(input.ocrText) ?? r.date,
    currencyCode: "AUD",
    total,
    gst,
    category: r.category,
    deductible,
    lineItems: reconcileLineItems(
      r.lineItems
        .filter((li) => !isNoiseItem(li.name))
        .map((li) => ({ name: li.name, price: roundCents(li.price) })),
      trimReceiptTail(input.ocrText),
      total,
    ),
    confidence,
    needsReview: confidence < 0.8,
  };
}

/** The deterministic fallback at the end of the ladder: heuristic + needsReview + graded confidence. */
export function fallback(input: ExtractionInput): ExtractedReceipt {
  const h = heuristicExtract(trimReceiptTail(input.ocrText), input.defaultDate);
  return {
    merchant: detectMerchant(input.ocrText) ?? h.merchant,
    date: detectDate(input.ocrText) ?? h.date,
    currencyCode: "AUD",
    total: h.total,
    gst: reconcileGst(h.total === 0 ? null : h.gst, h.total, input.ocrText),
    category: h.category,
    deductible: h.deductible,
    lineItems: reconcileLineItems(
      h.lineItems.filter((li) => !isNoiseItem(li.name)),
      trimReceiptTail(input.ocrText),
      h.total,
    ),
    confidence: h.confidence,
    needsReview: h.needsReview,
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
  // Trim the rewards/marketing/coupon tail so the model isn't tempted to extract promo
  // products (e.g. the BWS wine/beer block) as line items. GST is reconciled from the FULL
  // text in finalize(), so a trimmed GST line is fine.
  const userPrompt = `Extract the receipt as json. OCR text:\n${trimReceiptTail(input.ocrText)}`;

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
        return { receipt: finalize(input, parsed), meta: { model, attempts, stub: false, usedLlm: true } };
      }
    }
  }

  // All attempts exhausted — fell back to heuristic. usedLlm:false so the caller
  // does NOT burn a smart-scan slot (DeepSeek outage should not penalise the user).
  return { receipt: fallback(input), meta: { model, attempts, stub: false, usedLlm: false } };
}
