import Foundation

/// Invoice totals reuse the quote GST engine verbatim (spec §3): the invoice carries the
/// same GST-enabled / GST-inclusive semantics AND the same snapshotted `gstRateBp` as the
/// quote it came from.
enum InvoiceTotals {
    /// Compute (subtotal, gst, total) in integer cents from invoice line items.
    /// `gstRateBp` nil ⇒ 10% (QuoteTotals.defaultRateBp).
    static func compute(lineItems: [InvoiceLineItem], gstEnabled: Bool,
                        gstInclusive: Bool = false,
                        gstRateBp: Int? = nil) -> (subtotal: Int, gst: Int, total: Int) {
        QuoteTotals.compute(
            lineItems: lineItems.map { QuoteTotals.Line(quantity: $0.quantity, unitPriceCents: $0.unitPriceCents) },
            gstEnabled: gstEnabled, gstInclusive: gstInclusive, gstRateBp: gstRateBp)
    }
}
