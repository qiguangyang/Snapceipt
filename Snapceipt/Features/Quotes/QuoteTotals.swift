import Foundation

/// Pure quote-totals math, shared by the live editor UI and asserted to match the
/// backend send route (§4.2). GST is quote-level (10% AU, rounded to the nearest
/// cent, half-up). Two GST modes when enabled:
///   • exclusive (`gstInclusive == false`): entered prices are ex-GST; GST is added
///     on top. subtotal = Σ(line), gst = round(subtotal × 0.10), total = subtotal+gst.
///   • inclusive (`gstInclusive == true`): entered prices already contain GST; the
///     grand total stays the entered sum and GST is the embedded portion.
///     total = Σ(line), gst = round(total × 0.10/1.10), subtotal = total − gst.
/// In every mode the invariant `subtotal + gst == total` holds, and `subtotal` is the
/// ex-GST base / `gst` the tax component — so the persisted/PDF totals are identical.
enum QuoteTotals {
    /// 10% AU GST.
    static let rate = 0.10

    /// A minimal line input (decoupled from the `QuoteLineItem` @Model so the helper
    /// stays pure + trivially testable).
    struct Line {
        let quantity: Int
        let unitPriceCents: Int
    }

    /// Compute (subtotal, gst, total) in integer cents. `gstInclusive` only applies
    /// when `gstEnabled` is true. Mirrors `src/lib/quoteTotals.ts` exactly.
    static func compute(lineItems: [Line], gstEnabled: Bool,
                        gstInclusive: Bool = false) -> (subtotal: Int, gst: Int, total: Int) {
        let gross = lineItems.reduce(0) { $0 + $1.quantity * $1.unitPriceCents }
        guard gstEnabled else { return (gross, 0, gross) }
        if gstInclusive {
            // GST embedded in `gross`: gross × rate/(1+rate).
            let gst = Int((Double(gross) * rate / (1 + rate)).rounded())
            return (gross - gst, gst, gross)
        }
        let gst = Int((Double(gross) * rate).rounded())
        return (gross, gst, gross + gst)
    }

    /// Convenience overload for the editor: maps `QuoteLineItem`s to `Line`s.
    static func compute(lineItems: [QuoteLineItem], gstEnabled: Bool,
                        gstInclusive: Bool = false) -> (subtotal: Int, gst: Int, total: Int) {
        compute(lineItems: lineItems.map { Line(quantity: $0.quantity, unitPriceCents: $0.unitPriceCents) },
                gstEnabled: gstEnabled, gstInclusive: gstInclusive)
    }
}
