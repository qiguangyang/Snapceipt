import Foundation

/// Pure quote-totals math, shared by the live editor UI and asserted to match the
/// backend send route. GST is quote-level, rate-configurable (basis points), rounded
/// to the nearest cent (half-up). null ⇒ 1000 (10% AU). Two GST modes when enabled:
///   • exclusive (`gstInclusive == false`): entered prices are ex-GST; GST is added on
///     top. subtotal = Σ(line), gst = round(subtotal × bp / 10000), total = subtotal+gst.
///   • inclusive (`gstInclusive == true`): entered prices already contain GST; the grand
///     total stays the entered sum and GST is the embedded portion.
///     gross = Σ(line), gst = round(gross × bp / (10000 + bp)), subtotal = gross − gst.
/// In every mode the invariant `subtotal + gst == total` holds. Mirrors
/// `src/lib/quoteTotals.ts` exactly. (spec §3)
enum QuoteTotals {
    /// Default GST rate in basis points (10% AU) used when a document/profile rate is nil.
    static let defaultRateBp = 1000

    /// A minimal line input (decoupled from the `QuoteLineItem` @Model so the helper
    /// stays pure + trivially testable).
    struct Line {
        let quantity: Int
        let unitPriceCents: Int
    }

    /// Compute (subtotal, gst, total) in integer cents. `gstInclusive` only applies when
    /// `gstEnabled` is true. `gstRateBp` nil ⇒ `defaultRateBp` (10%).
    static func compute(lineItems: [Line], gstEnabled: Bool,
                        gstInclusive: Bool = false,
                        gstRateBp: Int? = nil) -> (subtotal: Int, gst: Int, total: Int) {
        let gross = lineItems.reduce(0) { $0 + $1.quantity * $1.unitPriceCents }
        guard gstEnabled else { return (gross, 0, gross) }
        let bp = gstRateBp ?? defaultRateBp
        if gstInclusive {
            // GST embedded in `gross`: round(gross × bp / (10000 + bp)).
            let gst = Int((Double(gross) * Double(bp) / Double(10_000 + bp)).rounded())
            return (gross - gst, gst, gross)
        }
        // GST added on top: round(subtotal × bp / 10000).
        let gst = Int((Double(gross) * Double(bp) / 10_000.0).rounded())
        return (gross, gst, gross + gst)
    }

    /// Convenience overload for the editor: maps `QuoteLineItem`s to `Line`s.
    static func compute(lineItems: [QuoteLineItem], gstEnabled: Bool,
                        gstInclusive: Bool = false,
                        gstRateBp: Int? = nil) -> (subtotal: Int, gst: Int, total: Int) {
        compute(lineItems: lineItems.map { Line(quantity: $0.quantity, unitPriceCents: $0.unitPriceCents) },
                gstEnabled: gstEnabled, gstInclusive: gstInclusive, gstRateBp: gstRateBp)
    }
}
