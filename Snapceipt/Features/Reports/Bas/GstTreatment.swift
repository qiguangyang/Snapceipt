import Foundation

/// The per-transaction GST authority rule (spec §4.3/§4.6): a txn is either taxable
/// with a GST amount, or GST-free with gstCents == 0. The SINGLE mutation path for
/// classification — the capture editor, the BAS reconciliation quick-fix, and the
/// income-confirm affordance all route through it so provenance stays consistent.
/// Pure (no SwiftData) so it is unit-testable.
enum GstTreatment {
    struct Result: Equatable {
        let gstCents: Int?
        let gstSource: String?   // "derived" | "manual" | nil
    }

    /// round(totalCents × bp / (10000 + bp)), half-up. `totalCents` is the magnitude
    /// (>= 0). `bp` is the profile's GST rate in basis points (default 1000 = 10%, which
    /// reduces to the legacy ÷11). (spec §3)
    static func derivedGstCents(totalCents: Int, bp: Int = 1000) -> Int {
        Int((Double(totalCents) * Double(bp) / Double(10_000 + bp)).rounded())
    }

    /// Toggle gstFree. true ⇒ gstCents=0, gstSource=nil. false ⇒ re-derive at `bp`
    /// (gstSource="derived"). `totalCents` is the magnitude of the txn amount.
    static func applyGstFree(_ gstFree: Bool, totalCents: Int, bp: Int = 1000) -> Result {
        if gstFree { return Result(gstCents: 0, gstSource: nil) }
        return Result(gstCents: derivedGstCents(totalCents: totalCents, bp: bp), gstSource: "derived")
    }

    /// User typed an exact GST amount → manual provenance (overrides ÷11).
    static func applyManualGst(_ cents: Int) -> Result {
        Result(gstCents: max(0, cents), gstSource: "manual")
    }

    /// User has reviewed an INCOME row (confirmed taxable vs GST-free). Income GST is
    /// not split per-txn, so this only stamps provenance = "manual" — the signal
    /// `BasViewModel.recompute`/`BasReconciliation` read to clear the income-to-confirm
    /// count and flip the headline from "Estimated" to firm.
    static func confirmIncome() -> Result {
        Result(gstCents: nil, gstSource: "manual")
    }
}
