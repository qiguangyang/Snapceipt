// src/lib/extractionHeuristic.ts
// The SINGLE deterministic receipt extractor, reused by BOTH the dev/E2E stub
// (POST /extract when no DeepSeek key) AND the always-invalid fallback at the
// end of the DeepSeek retry ladder. Pure + dependency-free: same input ->
// same output, so the stub seam is fully reproducible in tests.

export interface HeuristicLineItem {
  name: string;
  price: number;
}

export interface HeuristicReceipt {
  merchant: string;
  date: string; // YYYY-MM-DD
  total: number; // dollars, >= 0
  gst: number; // dollars (printed line or round(total/11)); 0 when total == 0
  category: "office"; // the safe-fallback category
  deductible: 100; // the safe-fallback deductible
  lineItems: HeuristicLineItem[];
}

/** Round to 2dp avoiding binary float drift (e.g. 9.0909 -> 9.09). */
function roundCents(n: number): number {
  return Math.round(n * 100) / 100;
}

/** A line that contains at least one ASCII letter (used to pick the merchant). */
function isLetterRich(line: string): boolean {
  return /[A-Za-z]/.test(line) && line.trim().length >= 2;
}

/** Parse the FIRST dollar-ish amount in a line, e.g. "Coffee $5.00" -> 5. */
function amountIn(line: string): number | null {
  const m = line.match(/(?:\$\s*)?(\d{1,7}(?:,\d{3})*(?:\.\d{1,2})?)/);
  if (!m || m[1] === undefined) return null;
  const n = Number(m[1].replace(/,/g, ""));
  return Number.isFinite(n) ? n : null;
}

/**
 * Parse the FIRST amount that carries an explicit `.NN` cents component, e.g.
 * "TOTAL 42.50" -> 42.5, but "ABN 12 345 678 901" / "2026" -> null. Used ONLY
 * for total selection so a bare 4-digit year/ABN/postcode can never be chosen
 * as the grand total.
 */
function centsAmountIn(line: string): number | null {
  const m = line.match(/(?:\$\s*)?(\d{1,7}(?:,\d{3})*\.\d{2})\b/);
  if (!m || m[1] === undefined) return null;
  const n = Number(m[1].replace(/,/g, ""));
  return Number.isFinite(n) ? n : null;
}

/** Parse a DD/MM/YYYY (or DD-MM-YYYY) or an already-ISO date to YYYY-MM-DD. */
function parseDate(text: string): string | null {
  const iso = text.match(/(\d{4})-(\d{2})-(\d{2})/);
  if (iso) return `${iso[1]}-${iso[2]}-${iso[3]}`;
  const au = text.match(/\b(\d{1,2})[/-](\d{1,2})[/-](\d{2,4})\b/);
  if (au && au[1] !== undefined && au[2] !== undefined && au[3] !== undefined) {
    const d = au[1];
    const mo = au[2];
    let y = au[3];
    if (y.length === 2) y = `20${y}`;
    const dd = d.padStart(2, "0");
    const mm = mo.padStart(2, "0");
    if (Number(mm) >= 1 && Number(mm) <= 12 && Number(dd) >= 1 && Number(dd) <= 31) {
      return `${y}-${mm}-${dd}`;
    }
  }
  return null;
}

/** Lines that are summary/metadata, not purchasable line items. */
function isSummaryLine(line: string): boolean {
  return /\b(total|subtotal|gst|tax|change|cash|eftpos|balance|amount\s*due|tendered)\b/i.test(
    line,
  );
}

export function heuristicExtract(ocrText: string, defaultDate: string): HeuristicReceipt {
  const rawLines = ocrText.split(/\r?\n/).map((l) => l.trim()).filter((l) => l.length > 0);

  // Merchant: the first letter-rich line that isn't a pure date/amount.
  let merchant = "";
  for (const line of rawLines) {
    if (isLetterRich(line) && parseDate(line) === null) {
      merchant = line;
      break;
    }
  }

  // Total: the largest CENTS-BEARING dollar amount anywhere in the text (>= 0).
  // Cents-only (centsAmountIn) + skipping any date line prevents a bare 4-digit
  // year/ABN/postcode (e.g. 2026 on "28/05/2026", or an ABN) from being picked
  // as the total when it happens to exceed the real grand total.
  let total = 0;
  for (const line of rawLines) {
    if (parseDate(line) !== null) continue; // never read a total off a date line
    const a = centsAmountIn(line);
    if (a !== null && a > total) total = a;
  }
  total = roundCents(Math.max(0, total));

  // Date: first parseable date, else the caller-provided default (capturedAt/today).
  let date = defaultDate;
  for (const line of rawLines) {
    const d = parseDate(line);
    if (d) {
      date = d;
      break;
    }
  }

  // GST: a printed GST/tax line wins; otherwise infer round(total/11).
  let gst: number | null = null;
  for (const line of rawLines) {
    if (/\b(gst|tax)\b/i.test(line)) {
      const a = amountIn(line);
      if (a !== null) {
        gst = roundCents(a);
        break;
      }
    }
  }
  if (gst === null) gst = total > 0 ? roundCents(total / 11) : 0;

  // Line items: letter-rich, non-summary lines that carry an amount. Prefer a
  // CENTS-BEARING price (e.g. "9.00") so a bare quantity digit like the `2` in
  // "Flat White x2" is never mistaken for the price — and strip ONLY the trailing
  // price token from the name so the quantity stays put.
  const lineItems: HeuristicLineItem[] = [];
  for (const line of rawLines) {
    if (line === merchant) continue;
    if (isSummaryLine(line)) continue;
    if (!isLetterRich(line)) continue;
    const cents = centsAmountIn(line);
    const price = cents ?? amountIn(line);
    if (price === null) continue;
    // Remove the trailing price token (cents-bearing wins) from the name; keep
    // any leading quantity digits (e.g. "x2") intact.
    const priceToken = cents !== null
      ? /(?:\$\s*)?\d{1,7}(?:,\d{3})*\.\d{2}\s*$/
      : /(?:\$\s*)?\d{1,7}(?:,\d{3})*(?:\.\d{1,2})?\s*$/;
    const name = line.replace(priceToken, "").replace(/\s{2,}/g, " ").trim();
    if (name.length === 0) continue;
    lineItems.push({ name, price: roundCents(price) });
  }

  return {
    merchant,
    date,
    total,
    gst,
    category: "office",
    deductible: 100,
    lineItems,
  };
}
