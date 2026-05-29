import Foundation

/// Canonical money value: integer **cents** (AUD), with a `Decimal` bridge.
/// All persisted amounts in Snapceipt are stored as `Int` cents; `Money`
/// is the in-memory helper for converting to/from `Decimal` dollars
/// (keypad input, GST math) without ever using binary floating point.
struct Money: Equatable, Hashable, Codable, Sendable {
    /// Amount in whole cents. Negative = expense, positive = income.
    var cents: Int

    init(cents: Int) {
        self.cents = cents
    }

    /// The amount as a `Decimal` number of dollars (e.g. `4250` cents -> `42.50`).
    var decimal: Decimal {
        Decimal(cents) / 100
    }

    /// Build from a `Decimal` dollar amount, rounding to the nearest cent.
    static func fromDecimal(_ dollars: Decimal) -> Money {
        var scaled = dollars * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return Money(cents: (rounded as NSDecimalNumber).intValue)
    }

    /// Build from an integer dollar amount (convenience for seeds/tests).
    static func fromDollars(_ dollars: Int) -> Money {
        Money(cents: dollars * 100)
    }

    static let zero = Money(cents: 0)
}
