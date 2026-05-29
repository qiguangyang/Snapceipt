import Testing
import SwiftUI
@testable import Snapceipt

@Suite("BarPair height math")
struct BarPairMathTests {

    @Test("tallest value fills the full column area (height - 22)")
    func tallestFillsArea() {
        let data = [
            BarPairDatum(label: "Jan", income: 100, expense: 50),
            BarPairDatum(label: "Feb", income: 60, expense: 40),
        ]
        let bars = BarPair.barHeights(data: data, height: 120)
        let area = 120 - 22.0
        #expect(abs(bars[0].income - area) < 0.0001)        // 100 is the max
        #expect(abs(bars[0].expense - area * 0.5) < 0.0001) // 50/100
    }

    @Test("scales proportionally to the global max across income+expense")
    func proportionalScaling() {
        let data = [BarPairDatum(label: "Mar", income: 25, expense: 75)]
        let bars = BarPair.barHeights(data: data, height: 122)
        let area = 122 - 22.0
        #expect(abs(bars[0].income - area * (25.0 / 75.0)) < 0.0001)
        #expect(abs(bars[0].expense - area) < 0.0001) // 75 is the global max
    }

    @Test("empty data yields empty heights (no divide-by-zero)")
    func emptyData() {
        let bars = BarPair.barHeights(data: [], height: 120)
        #expect(bars.isEmpty)
    }

    @Test("all-zero data clamps max to 1 so heights are zero, not NaN")
    func allZeroNoNaN() {
        let data = [BarPairDatum(label: "Z", income: 0, expense: 0)]
        let bars = BarPair.barHeights(data: data, height: 120)
        #expect(bars[0].income == 0)
        #expect(bars[0].expense == 0)
        #expect(!bars[0].income.isNaN)
    }
}
