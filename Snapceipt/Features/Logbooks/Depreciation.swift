import Foundation

/// Pure, simplified first-year car depreciation helper (labelled "simplified
/// estimate — not tax advice" in the UI). Caps the depreciable base at the FY2025-26
/// car cost limit and prorates the first year by days held. (§5.4)
enum Depreciation {
    enum Method: String, CaseIterable, Identifiable {
        case diminishingValue
        case primeCost
        var id: String { rawValue }
        var label: String { self == .diminishingValue ? "Diminishing value" : "Prime cost" }
    }

    /// ATO car cost limit for FY2025-26, in cents ($69,674).
    static let carCostLimitCents = 69_674_00

    /// Cost capped at the car cost limit.
    static func cappedCostCents(_ costCents: Int) -> Int {
        min(costCents, carCostLimitCents)
    }

    /// First-year decline in value, in cents.
    /// - DV: base * (2 / life) * daysHeld/365
    /// - PC: base * (1 / life) * daysHeld/365
    static func declineCents(costCents: Int, method: Method, effectiveLifeYears: Int, daysHeld: Int) -> Int {
        guard effectiveLifeYears > 0 else { return 0 }
        let base = Double(cappedCostCents(costCents))
        let rate = (method == .diminishingValue ? 2.0 : 1.0) / Double(effectiveLifeYears)
        let proration = Double(daysHeld) / 365.0
        return Int((base * rate * proration).rounded())
    }
}
