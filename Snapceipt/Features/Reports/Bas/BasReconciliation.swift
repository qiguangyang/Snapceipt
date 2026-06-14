import Foundation

/// Pure trust-layer helpers over a period's transactions (spec §4.6). Drives the
/// reconciliation strip + the "Estimated" → firm headline gate.
enum BasReconciliation {
    /// One reconcilable txn snapshot.
    struct Item: Equatable {
        let id: String
        let amountCents: Int       // signed
        let gstFree: Bool
        let gstSource: String?     // "printed" | "derived" | "manual" | nil
        let gstCents: Int?
        let incomeConfirmed: Bool  // user has confirmed taxable/GST-free for income
    }

    /// Taxable expenses whose GST was the ÷11 fallback (gstSource == "derived").
    static func estimatedGstCount(_ items: [Item]) -> Int {
        items.filter { $0.amountCents < 0 && $0.gstSource == "derived" }.count
    }

    /// Income entries not yet confirmed taxable/GST-free.
    static func incomeToConfirmCount(_ items: [Item]) -> Int {
        items.filter { $0.amountCents > 0 && !$0.incomeConfirmed }.count
    }

    /// The confident headline is gated on income being reviewed.
    static func isHeadlineEstimated(_ items: [Item]) -> Bool {
        incomeToConfirmCount(items) > 0
    }

    /// A printed GST line disagrees with round(total/11) by more than the tolerance
    /// max(2 cents, 1% of total). `totalCents` is the magnitude (>= 0).
    static func isPrintedDiscrepant(totalCents: Int, printedGstCents: Int) -> Bool {
        let derived = Int((Double(totalCents) / 11.0).rounded())
        let tolerance = max(2, Int((Double(totalCents) * 0.01).rounded()))
        return abs(printedGstCents - derived) > tolerance
    }

    /// Printed-line discrepancies among the period items (printed source only).
    static func printedDiscrepancyCount(_ items: [Item]) -> Int {
        items.filter {
            $0.amountCents < 0 && $0.gstSource == "printed"
            && isPrintedDiscrepant(totalCents: -$0.amountCents, printedGstCents: $0.gstCents ?? 0)
        }.count
    }
}
