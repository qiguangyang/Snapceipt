/**
 * Pure quote-totals recompute (spec §4.2). The send route calls this to
 * recompute totals authoritatively from the persisted line items before
 * rendering the PDF. iOS computes the identical formula on-device for the live
 * UI; this is the server's source of truth.
 *
 *   subtotalCents = Σ(quantity × unitPriceCents)
 *   gstCents      = gstEnabled ? round(subtotalCents × 0.10) : 0   (10% AU GST)
 *   totalCents    = subtotalCents + gstCents
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
): QuoteTotals {
  let subtotalCents = 0;
  for (const li of lineItems) {
    subtotalCents += li.quantity * li.unitPriceCents;
  }
  const gstCents = gstEnabled ? Math.round(subtotalCents * GST_RATE) : 0;
  return { subtotalCents, gstCents, totalCents: subtotalCents + gstCents };
}
