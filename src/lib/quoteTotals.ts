/**
 * Pure quote-totals recompute (spec §4.2). The send route calls this to
 * recompute totals authoritatively from the persisted line items before
 * rendering the PDF. iOS computes the identical formula on-device for the live
 * UI (`Snapceipt/Features/Quotes/QuoteTotals.swift`); this is the server's
 * source of truth — keep the two in lock-step.
 *
 * `gross = Σ(quantity × unitPriceCents)`. With GST enabled, two modes:
 *   • exclusive (`gstInclusive === false`): entered prices are ex-GST, GST added
 *     on top — subtotal = gross, gst = round(gross × 0.10), total = gross + gst.
 *   • inclusive (`gstInclusive === true`): entered prices already contain GST —
 *     total = gross, gst = round(gross × 0.10/1.10), subtotal = gross − gst.
 * The invariant `subtotalCents + gstCents === totalCents` holds in every mode;
 * `subtotalCents` is always the ex-GST base and `gstCents` the tax component.
 */

const GST_RATE = 0.1; // 10% AU GST.

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
): QuoteTotals {
  let gross = 0;
  for (const li of lineItems) {
    gross += li.quantity * li.unitPriceCents;
  }
  if (!gstEnabled) {
    return { subtotalCents: gross, gstCents: 0, totalCents: gross };
  }
  if (gstInclusive) {
    // GST embedded in `gross`: gross × rate/(1+rate).
    const gstCents = Math.round((gross * GST_RATE) / (1 + GST_RATE));
    return { subtotalCents: gross - gstCents, gstCents, totalCents: gross };
  }
  const gstCents = Math.round(gross * GST_RATE);
  return { subtotalCents: gross, gstCents, totalCents: gross + gstCents };
}
