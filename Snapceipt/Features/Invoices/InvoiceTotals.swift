import Foundation

/// Invoice totals reuse the quote GST engine verbatim (spec §4.1/§8): the invoice
/// carries the same GST-enabled / GST-inclusive semantics as the quote it came from.
enum InvoiceTotals {
    /// Compute (subtotal, gst, total) in integer cents from invoice line items.
    static func compute(lineItems: [InvoiceLineItem], gstEnabled: Bool,
                        gstInclusive: Bool = false) -> (subtotal: Int, gst: Int, total: Int) {
        QuoteTotals.compute(
            lineItems: lineItems.map { QuoteTotals.Line(quantity: $0.quantity, unitPriceCents: $0.unitPriceCents) },
            gstEnabled: gstEnabled, gstInclusive: gstInclusive)
    }
}
