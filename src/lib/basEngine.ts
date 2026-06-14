/**
 * BAS GST worksheet (spec §4.3). Pure: aggregate the period's non-deleted txns
 * into the full G1–G20 worksheet + 1A/1B/8A/8B/9 + 5A + total, all in CENTS.
 * Income vs purchase is SIGN ONLY (amountCents > 0 = sale, < 0 = purchase).
 * 1A/1B use the worksheet method — one round(aggregate/11) on the aggregate, NOT
 * a sum of per-txn rounds. 1A is forced 0 when !gstRegistered. Mirrored byte-for-
 * byte by the Swift BasEngine; both assert test/fixtures/bas-golden.json.
 */

/**
 * Capital purchases at or below this magnitude fall to G11 (ATO threshold,
 * <$1M turnover). EXPORTED single source of truth — csvBas.ts imports this so the
 * CSV per-row label split (G10 vs G11) cannot drift from the engine's G10 aggregate.
 */
export const CAPITAL_THRESHOLD_CENTS = 100000; // $1,000

/** A single transaction as the engine reads it (sign = income/purchase). */
export interface BasTxn {
  amountCents: number;
  gstFree: boolean;
  capital: boolean;
}

/** Manual BAS parameters; only paygInstalmentCents is user-editable in v1 (rest default 0). */
export interface BasManual {
  paygInstalmentCents?: number;
  exportsCents?: number;
  inputTaxedSalesCents?: number;
  salesAdjustmentCents?: number;
  inputTaxedPurchaseCents?: number;
  privateUseCents?: number;
  purchaseAdjustmentCents?: number;
}

export interface BasOptions {
  gstRegistered: boolean;
  manual?: BasManual;
}

/** The full worksheet output (cents). Field set is frozen against the golden fixture. */
export interface BasResult {
  g1: number; g2: number; g3: number; g4: number; g5: number; g6: number; g7: number; g8: number; g9: number;
  g10: number; g11: number; g12: number; g13: number; g14: number; g15: number; g16: number; g17: number; g18: number; g19: number; g20: number;
  oneA: number; oneB: number; eightA: number; eightB: number;
  netGstCents: number; paygCents: number; totalPayableCents: number;
}

/** Round half-away-from-zero on a non-negative aggregate, matching round(x/11). */
function gstOf(aggregateCents: number): number {
  return Math.round(aggregateCents / 11);
}

export function basEngine(txns: BasTxn[], opts: BasOptions): BasResult {
  const m = opts.manual ?? {};
  const payg = m.paygInstalmentCents ?? 0;

  // Sales (amountCents > 0).
  let g1 = 0;
  let g3 = 0; // other GST-free sales
  for (const t of txns) {
    if (t.amountCents > 0) {
      g1 += t.amountCents;
      if (t.gstFree) g3 += t.amountCents;
    }
  }
  const g2 = m.exportsCents ?? 0;
  const g4 = m.inputTaxedSalesCents ?? 0;
  const g5 = g2 + g3 + g4;
  const g6 = g1 - g5;
  const g7 = m.salesAdjustmentCents ?? 0;
  const g8 = g6 + g7;
  const g9 = opts.gstRegistered ? gstOf(g8) : 0; // 1A forced 0 when !registered

  // Purchases (amountCents < 0; magnitudes = -amountCents).
  let g10 = 0; // capital incl GST, |amount| > $1,000
  let expensesTotal = 0;
  let g14 = 0; // GST-free purchases
  for (const t of txns) {
    if (t.amountCents < 0) {
      const mag = -t.amountCents;
      expensesTotal += mag;
      if (t.capital && mag > CAPITAL_THRESHOLD_CENTS) g10 += mag;
      if (t.gstFree) g14 += mag;
    }
  }
  const g11 = expensesTotal - g10; // gstFree purchases stay in G11/G12 (G14 removes them at G16)
  const g12 = g10 + g11;
  const g13 = m.inputTaxedPurchaseCents ?? 0;
  const g15 = m.privateUseCents ?? 0;
  const g16 = g13 + g14 + g15;
  const g17 = g12 - g16;
  const g18 = m.purchaseAdjustmentCents ?? 0;
  const g19 = g17 + g18;
  const g20 = gstOf(g19);

  const oneA = g9;
  const oneB = g20;
  const eightA = oneA;
  const eightB = oneB;
  const netGstCents = eightA - eightB; // positive = pay, negative = refund
  const totalPayableCents = netGstCents + payg; // 5A kept separate, summed for headline

  return {
    g1, g2, g3, g4, g5, g6, g7, g8, g9,
    g10, g11, g12, g13, g14, g15, g16, g17, g18, g19, g20,
    oneA, oneB, eightA, eightB,
    netGstCents, paygCents: payg, totalPayableCents,
  };
}
