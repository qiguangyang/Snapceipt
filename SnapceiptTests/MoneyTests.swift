import Testing
import Foundation
@testable import Snapceipt

@Suite("Money")
struct MoneyTests {

    @Test func centsToDecimal() {
        #expect(Money(cents: 4250).decimal == Decimal(string: "42.50"))
        #expect(Money(cents: -4250).decimal == Decimal(string: "-42.50"))
        #expect(Money.zero.decimal == Decimal(0))
    }

    @Test func fromDecimalExact() {
        #expect(Money.fromDecimal(Decimal(string: "42.50")!).cents == 4250)
        #expect(Money.fromDecimal(Decimal(string: "850")!).cents == 85000)
    }

    @Test func fromDecimalRoundsToNearestCent() {
        // 42.505 -> 42.51 (half up), 42.504 -> 42.50
        #expect(Money.fromDecimal(Decimal(string: "42.505")!).cents == 4251)
        #expect(Money.fromDecimal(Decimal(string: "42.504")!).cents == 4250)
    }

    @Test func fromDollars() {
        #expect(Money.fromDollars(850).cents == 85000)
        #expect(Money.fromDollars(0) == Money.zero)
    }

    @Test func roundTripThroughDecimal() {
        for c in [0, 1, 99, 4250, -4250, 99_999_99] {
            #expect(Money.fromDecimal(Money(cents: c).decimal).cents == c)
        }
    }
}
