import Foundation

/// Pure ATO logbook-method mileage math. No SwiftData — callers pass `Trip`/`Costs`
/// snapshots so this stays unit-testable. (§5.3)
enum MileageCalc {
    /// A minimal trip snapshot for aggregation.
    struct Trip: Equatable {
        let tripDate: String   // "yyyy-MM-dd"
        let distanceM: Int
        let isBusiness: Bool
    }

    /// Annual running costs.
    struct Costs: Equatable {
        let fuelCents: Int
        let regoCents: Int
        let insuranceCents: Int
        let servicingCents: Int
        let otherCents: Int
        let depreciationCents: Int
        var totalCents: Int {
            fuelCents + regoCents + insuranceCents + servicingCents + otherCents + depreciationCents
        }
    }

    /// FY mileage hero stats.
    struct Hero: Equatable {
        let businessKm: Double
        let tripCount: Int
    }

    /// Derived distance = end - start metres, or nil when missing/non-increasing.
    static func distanceM(startM: Int?, endM: Int?) -> Int? {
        guard let s = startM, let e = endM, e > s else { return nil }
        return e - s
    }

    /// True when both odometers are present and end > start.
    static func isValidOdometer(startM: Int?, endM: Int?) -> Bool {
        guard let s = startM, let e = endM else { return false }
        return e > s
    }

    /// Business-use % over trips inside [start, end] (inclusive). Nil when no
    /// in-window km. `start`/`end` are "yyyy-MM-dd".
    static func businessUsePct(trips: [Trip], start: String, end: String) -> Int? {
        let inWindow = trips.filter { $0.tripDate >= start && $0.tripDate <= end }
        let totalM = inWindow.reduce(0) { $0 + $1.distanceM }
        guard totalM > 0 else { return nil }
        let businessM = inWindow.filter { $0.isBusiness }.reduce(0) { $0 + $1.distanceM }
        return Int((Double(businessM) / Double(totalM) * 100).rounded())
    }

    /// vehicle_year claim = round(pct/100 * sum(costs)).
    static func claimCents(businessUsePct: Int, costs: Costs) -> Int {
        Int((Double(businessUsePct) / 100.0 * Double(costs.totalCents)).rounded())
    }

    /// FY hero: business-trip km + count of trips in FY `fyStartYear`.
    static func hero(trips: [Trip], fyStartYear: Int, startMonth: Int) -> Hero {
        let inFY = trips.filter {
            FinancialYear.isIn($0.tripDate, fyStartYear: fyStartYear, startMonth: startMonth)
        }
        let businessM = inFY.filter { $0.isBusiness }.reduce(0) { $0 + $1.distanceM }
        return Hero(businessKm: Double(businessM) / 1000.0, tripCount: inFY.count)
    }
}
