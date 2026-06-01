import Foundation

/// Pure quote-totals math, shared by the live editor UI and asserted to match the
/// backend send route (§4.2). GST is quote-level (per `gstEnabled`), 10% AU, rounded
/// to the nearest cent (half-up).
enum QuoteTotals {
    /// A minimal line input (decoupled from the `QuoteLineItem` @Model so the helper
    /// stays pure + trivially testable).
    struct Line {
        let quantity: Int
        let unitPriceCents: Int
    }

    /// subtotal = Σ(quantity × unitPriceCents); gst = round(subtotal × 0.10) iff enabled;
    /// total = subtotal + gst. All in integer cents.
    static func compute(lineItems: [Line], gstEnabled: Bool) -> (subtotal: Int, gst: Int, total: Int) {
        let subtotal = lineItems.reduce(0) { $0 + $1.quantity * $1.unitPriceCents }
        let gst = gstEnabled ? Int((Double(subtotal) * 0.10).rounded()) : 0
        return (subtotal, gst, subtotal + gst)
    }

    /// Convenience overload for the editor: maps `QuoteLineItem`s to `Line`s.
    static func compute(lineItems: [QuoteLineItem], gstEnabled: Bool) -> (subtotal: Int, gst: Int, total: Int) {
        compute(lineItems: lineItems.map { Line(quantity: $0.quantity, unitPriceCents: $0.unitPriceCents) },
                gstEnabled: gstEnabled)
    }
}
