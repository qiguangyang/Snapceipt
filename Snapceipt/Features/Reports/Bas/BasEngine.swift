import Foundation

/// Pure AU GST calculation worksheet (spec §4.3), identical math to the backend
/// `basEngine.ts`, golden-vector-locked. Income vs purchase = SIGN ONLY
/// (amountCents > 0 = sale, < 0 = purchase). All values in cents; the screen/PDF
/// round to whole dollars. Worksheet method: 1A/1B = round(aggregate / 11) once.
enum BasEngine {
    /// Minimal txn snapshot the engine needs (caller filters to the period window).
    struct Txn: Equatable {
        let amountCents: Int     // signed
        let gstFree: Bool
        let capital: Bool
        let txnDate: String      // "yyyy-MM-dd" (caller already in-window)
    }

    /// Manual worksheet parameters (only paygInstalmentCents is user-editable in v1;
    /// the rest are engine params fixed at 0 per spec §4.9).
    struct Manual: Equatable {
        var paygInstalmentCents: Int = 0
        var exportsCents: Int = 0
        var inputTaxedSalesCents: Int = 0
        var salesAdjustmentCents: Int = 0
        var inputTaxedPurchaseCents: Int = 0
        var privateUseCents: Int = 0
        var purchaseAdjustmentCents: Int = 0
    }

    /// The full worksheet result (cents).
    struct Result: Equatable {
        let g1, g2, g3, g4, g5, g6, g7, g8: Int
        let oneA: Int            // G9
        let g10, g11, g12, g13, g14, g15, g16, g17, g18, g19: Int
        let oneB: Int            // G20
        let eightA, eightB: Int
        let netGstCents: Int     // label 9 = 8A − 8B
        let paygCents: Int       // label 5A
        let totalPayableCents: Int
    }

    /// ATO capital threshold for turnover < $1M: > $1,000 → G10, else G11.
    static let capitalThresholdCents = 100_000

    /// round(value / 11), half-up.
    private static func divEleven(_ value: Int) -> Int { Int((Double(value) / 11.0).rounded()) }

    static func compute(txns: [Txn], gstRegistered: Bool, manual: Manual) -> Result {
        // Sales (amount > 0).
        let g1 = txns.filter { $0.amountCents > 0 }.reduce(0) { $0 + $1.amountCents }
        let g2 = manual.exportsCents
        let g3 = txns.filter { $0.amountCents > 0 && $0.gstFree }.reduce(0) { $0 + $1.amountCents }
        let g4 = manual.inputTaxedSalesCents
        let g5 = g2 + g3 + g4
        let g6 = g1 - g5
        let g7 = manual.salesAdjustmentCents
        let g8 = g6 + g7
        let oneA = gstRegistered ? divEleven(g8) : 0

        // Purchases (amount < 0; magnitudes are −amount).
        let expenses = txns.filter { $0.amountCents < 0 }
        let totalExpense = expenses.reduce(0) { $0 + (-$1.amountCents) }
        let g10 = expenses.filter { $0.capital && (-$0.amountCents) > capitalThresholdCents }
            .reduce(0) { $0 + (-$1.amountCents) }
        let g11 = totalExpense - g10
        let g12 = g10 + g11
        let g13 = manual.inputTaxedPurchaseCents
        let g14 = expenses.filter { $0.gstFree }.reduce(0) { $0 + (-$1.amountCents) }
        let g15 = manual.privateUseCents
        let g16 = g13 + g14 + g15
        let g17 = g12 - g16
        let g18 = manual.purchaseAdjustmentCents
        let g19 = g17 + g18
        let oneB = divEleven(g19)

        let eightA = oneA
        let eightB = oneB
        let net = eightA - eightB
        let payg = manual.paygInstalmentCents
        return Result(g1: g1, g2: g2, g3: g3, g4: g4, g5: g5, g6: g6, g7: g7, g8: g8,
                      oneA: oneA, g10: g10, g11: g11, g12: g12, g13: g13, g14: g14, g15: g15,
                      g16: g16, g17: g17, g18: g18, g19: g19, oneB: oneB,
                      eightA: eightA, eightB: eightB, netGstCents: net,
                      paygCents: payg, totalPayableCents: net + payg)
    }
}
