// src/lib/deepseek.ts
import type { Env } from "../env";
import {
  deepseekReceiptSchema,
  type DeepseekReceipt,
} from "../schemas/extract";

// 15s abort budget per Gemini call: a stalled call fails fast while a healthy ~11s call
// still fits, so the server never keeps working after the client (35s /extract budget) has
// already given up. See APIClient.extract (timeout: 35).
const TIMEOUT_MS = 15_000;

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
  "You extract structured data from a photo or scan of a retail receipt or tax invoice from Australia, New Zealand, the United States, or Canada. Respond with ONLY a json object, no prose, no markdown fences:",
  '{ "merchant": string, "date": "YYYY-MM-DD", "currencyCode": one of ["AUD","NZD","USD","CAD"], "total": number, "gst": number|null, "category": one of ["meals","groceries","fuel","software","office","home","health","travel","income"], "deductible": number 0-100|null, "lineItems": [{"name": string, "price": number}], "confidence": number 0-1 }',
  'Country/currency: infer from the receipt — language, the address/state/province, phone format, and tax wording (AU & NZ say "GST"; Canada says "GST"/"HST"/"PST"/"QST"; the US says "Sales Tax" or "Tax"). Set `currencyCode` to AUD, NZD, USD, or CAD; if genuinely ambiguous (all four use "$"), default to AUD.',
  '`category` MUST be exactly one of the nine keys above (no others). Set `deductible` to the per-category default unless the receipt clearly implies otherwise: meals 50, groceries 0, fuel 100, software 100, office 100, home 50, health 0, travel 100, income null. `total` is the grand total actually paid (tax included) as a positive number. Use `income` only for money received.',
  'Tax (`gst` = the receipt\'s TOTAL tax amount): if a tax amount is printed (GST/HST/PST/QST/Sales Tax — sum them if several are shown), use that EXACT printed value. AU & NZ GST is INCLUDED in the total; US & Canadian sales tax is ADDED on top. If NO tax is printed: for AUD set `gst` to total/11; for NZD set it to total×3/23; for USD and CAD set `gst` to null (sales-tax rates vary and cannot be inferred). Never overwrite a printed tax with a formula.',
  '`lineItems` are ONLY actually-purchased products. EXCLUDE: payment/card/EFTPOS/balance/change/approval blocks; loyalty/rewards/points/credits; store/ABN/GST-number/tax-ID/legal/contact/terminal details; barcodes; savings or "you saved" lines; subtotals, tax lines, and totals; and promotional/advertising/coupon offers (e.g. "BUY ANY 2 WINES", BWS beer/wine specials, "PRESENT YOUR COUPON"). A product name and its price may be on SEPARATE lines (e.g. "Kiwifruit Gold New Zealand" then "0.977 kg NET @ $10.90/kg 10.65") — pair them so `name` is the PRODUCT (\"Kiwifruit Gold New Zealand\"), not the weight/qty line. Each `price` is the line\'s RIGHTMOST dollar amount = the line total (10.65), NEVER a per-unit price ("$10.90/kg", "$2.50 each") and NEVER a size/weight token ("130g", "750ml", "1kg") — those are not prices.',
].join("\n");

export interface ExtractionInput {
  ocrText: string;
  // Layout-reconstructed text (visual rows). PREFERRED input for the model + GST/heuristic
  // guards via extractionText(): the rows pair name↔price and label↔amount. Raw OCR order on
  // a two-column receipt separates descriptions from amounts (all names, then all prices),
  // which made the model emit header lines as items and miss the total/GST entirely. Falls
  // back to ocrText when no usable layout was supplied (e.g. email_in plain text).
  layoutText?: string;
  source: "scan" | "email_in";
  defaultDate: string; // capturedAt or today, used for the date fallback
}

/** The text the model + deterministic guards read: prefer the row-paired layoutText, fall
 * back to raw ocrText when no usable layout was supplied. See ExtractionInput.layoutText. */
function extractionText(input: ExtractionInput): string {
  const layout = input.layoutText?.trim();
  return layout && layout.length > 0 ? input.layoutText! : input.ocrText;
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

/** Supported receipt locales: Australia, New Zealand, the US, and Canada. */
const SUPPORTED_CURRENCIES = new Set(["AUD", "NZD", "USD", "CAD"]);

/** Normalize the model's currency to a supported ISO code; default AUD (the primary market) when
 * the receipt is ambiguous or the code is unrecognized. */
export function normalizeCurrency(code: string | null | undefined): string {
  const c = (code ?? "").trim().toUpperCase();
  return SUPPORTED_CURRENCIES.has(c) ? c : "AUD";
}

/** Max tax on a tax-INCLUSIVE total: AU GST 10% → total/11, NZ GST 15% → total×3/23. Returns
 * null for tax-EXCLUSIVE locales (US sales tax, Canada GST/HST/PST), where tax is added on top
 * and the rate varies — there is no formula to infer or cap it, so the printed amount is trusted. */
export function inclusiveTaxCap(currency: string, total: number): number | null {
  if (currency === "AUD") return roundCents(total / 11);
  if (currency === "NZD") return roundCents((total * 3) / 23);
  return null; // USD / CAD — exclusive, variable-rate sales tax
}

/** Reconcile the model's tax (the `gst` field carries the receipt's TOTAL tax) against the
 * receipt's currency. Prefer a printed "GST $X" line (text paths); otherwise, for tax-INCLUSIVE
 * currencies (AU/NZ) clamp an impossible model value down to the inclusive cap. For tax-EXCLUSIVE
 * currencies (US/CA) the printed/model amount stands (no formula cap). */
export function reconcileGst(
  gst: number | null, total: number, ocrText: string, currency: string,
): number | null {
  if (total <= 0) return null;
  // A printed tax line is authoritative. Allow headroom for surcharge/rounding: AU GST is ~10%
  // (accept up to 12%); other locales (NZ 15%, US/CA combined taxes) up to 30% — still rejecting
  // a gross mis-read of an ABN/payment figure.
  const printedCap = total * (currency === "AUD" ? 0.12 : 0.3);
  const printed = printedGst(ocrText);
  if (printed != null && printed >= 0 && printed <= printedCap) return roundCents(printed);
  // No trusted printed line: clamp an impossible MODEL value to the inclusive cap (AU/NZ only).
  const cap = inclusiveTaxCap(currency, total);
  if (cap != null && gst != null && gst > cap + 0.005) return cap;
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
  return /\b(sub ?total|total|eft(?:pos)?|balance|change|approved|redemption|merch|term id|card|tendered|rounding|you saved|present your|coupon|t&cs?)\b/i.test(
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
    /\b(sub ?total|total|gst|abn|tax invoice|eft(?:pos)?|balance|change|approved|redemption|merch|term id|card|you saved|promotional|count of items|rounding|description)\b/i;
  const lastAmount = (s: string): number | null => {
    const m = [...s.matchAll(amountRe)];
    return m.length ? parseFloat(m[m.length - 1][1].replace(/[, ]/g, "")) : null;
  };
  // A genuine line-total sits at the very END of the line (e.g. "... @ $10.90/kg 10.65" -> 10.65).
  // A detail/sub-line whose only amount is a UNIT price ends in "EACH"/"/kg" and has none.
  const trailingAmount = (s: string): number | null => {
    const m = s.match(/(-?\d{1,3}(?:[, ]\d{3})*\.\d{2})\s*$/);
    return m ? parseFloat(m[1].replace(/[, ]/g, "")) : null;
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
    if (detailRe.test(line)) {
      // Per-unit/per-kg/qty detail line. Only a TRAILING line-total makes it an item; a
      // sub-line whose only amount is a unit price ("2 @ $2.75 EACH", "1.261 kg NET @ $4.50/kg")
      // has none — skip it (don't push, don't consume the pendingName).
      const total = trailingAmount(line);
      if (total == null) continue;
      const name = pendingName ?? strip(line);
      if (name.length >= 2) items.push({ name, price: total });
      pendingName = null;
      continue;
    }
    const amt = lastAmount(line);
    if (amt == null) {
      const n = strip(line);
      pendingName = n.length >= 2 ? n : null;
      continue;
    }
    const name = strip(line);
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

  const currency = normalizeCurrency(r.currencyCode);

  // Tax (`gst` = the receipt's TOTAL tax). Infer the INCLUSIVE tax only for AU/NZ when the model
  // omitted it (AU total/11, NZ total×3/23); US/CA sales tax is exclusive + variable, so leave it
  // as the model read it (null if absent). total==0 → null.
  let gst = r.gst;
  if (total === 0) gst = null;
  else if (gst === null || gst === undefined) gst = inclusiveTaxCap(currency, total);
  else gst = roundCents(gst);
  // Deterministic guard: trust a printed tax line over the model; clamp impossible AU/NZ values.
  gst = reconcileGst(gst, total, extractionText(input), currency);

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
    // r.date may be null (schema allows it now); backfill from the OCR text, else the
    // capture date (capturedAt/today) so the wire date is always a valid YYYY-MM-DD.
    date: detectDate(input.ocrText) ?? r.date ?? input.defaultDate,
    currencyCode: currency,
    total,
    gst,
    category: r.category,
    deductible,
    lineItems: reconcileLineItems(
      r.lineItems
        .filter((li) => !isNoiseItem(li.name))
        .map((li) => ({ name: li.name, price: roundCents(li.price) })),
      trimReceiptTail(extractionText(input)),
      total,
    ),
    confidence,
    needsReview: confidence < 0.8,
  };
}

/** Base64-encode an ArrayBuffer in 0x8000-byte chunks. Spreading a whole large Uint8Array into
 * String.fromCharCode(...) overflows the call stack on real receipt images, so build the binary
 * string by concatenating subarray chunks, then btoa() it. */
function arrayBufferToBase64(buf: ArrayBuffer): string {
  const bytes = new Uint8Array(buf);
  const CHUNK = 0x8000;
  let binary = "";
  for (let i = 0; i < bytes.length; i += CHUNK) {
    binary += String.fromCharCode(...bytes.subarray(i, i + CHUNK));
  }
  return btoa(binary);
}

const GEMINI_BASE = "https://generativelanguage.googleapis.com/v1beta/models";

/** Gemini vision extraction: image → gemini-3.1-flash-lite → structured receipt in one call.
 * Same 15s abort budget as the DeepSeek caller. No OCR text → finalize()'s text guards no-op;
 * finalize still clamps total/gst and backfills the date. Throws on fetch/timeout/non-OK/unparseable
 * so the caller marks the txn failed (never a silent zeros receipt). */
export async function runGeminiVisionExtraction(
  env: Env, imageBytes: ArrayBuffer, contentType: string, defaultDate: string,
): Promise<DeepseekResult> {
  const model = env.GEMINI_MODEL ?? "gemini-3.1-flash-lite";
  const b64 = arrayBufferToBase64(imageBytes);
  const input: ExtractionInput = { ocrText: "", source: "email_in", defaultDate };
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    const res = await fetch(`${GEMINI_BASE}/${model}:generateContent`, {
      method: "POST",
      headers: { "x-goog-api-key": env.GEMINI_API_KEY, "content-type": "application/json" },
      body: JSON.stringify({
        contents: [{ parts: [
          { text: `${SYSTEM_PROMPT}\nExtract the receipt in this image as that json object.` },
          { inline_data: { mime_type: contentType, data: b64 } },
        ] }],
        generationConfig: { responseMimeType: "application/json", temperature: 0, maxOutputTokens: 1500 },
      }),
      signal: controller.signal,
    });
    if (!res.ok) throw new Error(`Gemini HTTP ${res.status}`);
    const json = (await res.json()) as { candidates?: { content?: { parts?: { text?: string }[] } }[] };
    const content = json.candidates?.[0]?.content?.parts?.[0]?.text ?? null;
    const parsed = content ? tryParseReceipt(content) : null;
    if (!parsed) throw new Error("Gemini returned no parseable JSON");
    return { receipt: finalize(input, parsed), meta: { model, attempts: 1, stub: false, usedLlm: true } };
  } finally { clearTimeout(timer); }
}
