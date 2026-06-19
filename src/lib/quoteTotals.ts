/**
 * Pure quote-totals recompute (spec §3). The send/link/HTML routes call this to
 * recompute totals authoritatively from the persisted line items. iOS computes the
 * identical formula on-device (`Snapceipt/Features/Quotes/QuoteTotals.swift`); this
 * is the server's source of truth — keep the two in lock-step.
 *
 * `gross = Σ(quantity × unitPriceCents)`. GST rate is basis points (bp): 1000 = 10%,
 * 1500 = 15%, 1250 = 12.5%. A null/absent rate is treated as 1000 (10%). With GST
 * enabled, two modes:
 *   • exclusive (gstInclusive === false): entered prices are ex-GST, GST added on top —
 *     subtotal = gross, gst = round(gross × bp / 10000), total = gross + gst.
 *   • inclusive (gstInclusive === true): entered prices already contain GST —
 *     total = gross, gst = round(gross × bp / (10000 + bp)), subtotal = gross − gst.
 * The invariant subtotalCents + gstCents === totalCents holds in every mode;
 * subtotalCents is always the ex-GST base and gstCents the tax component. At bp=1000
 * these reduce to the historical ×0.10 / ×0.10/1.10 behaviour.
 */

/** Default GST rate in basis points (10% AU GST) when a rate is null/absent. */
export const DEFAULT_GST_RATE_BP = 1000;

/** The two amounts needed per line item to recompute totals. */
export interface QuoteLineItemAmounts {
  quantity: number;
  unitPriceCents: number;
}

export interface QuoteTotals {
  subtotalCents: number;
  gstCents: number;
  totalCents: number;
}

export function recomputeTotals(
  lineItems: QuoteLineItemAmounts[],
  gstEnabled: boolean,
  gstInclusive = false,
  gstRateBp: number | null = DEFAULT_GST_RATE_BP,
): QuoteTotals {
  const bp = gstRateBp ?? DEFAULT_GST_RATE_BP;
  let gross = 0;
  for (const li of lineItems) {
    gross += li.quantity * li.unitPriceCents;
  }
  if (!gstEnabled) {
    return { subtotalCents: gross, gstCents: 0, totalCents: gross };
  }
  if (gstInclusive) {
    // GST embedded in `gross`: gross × bp / (10000 + bp).
    const gstCents = Math.round((gross * bp) / (10000 + bp));
    return { subtotalCents: gross - gstCents, gstCents, totalCents: gross };
  }
  const gstCents = Math.round((gross * bp) / 10000);
  return { subtotalCents: gross, gstCents, totalCents: gross + gstCents };
}
