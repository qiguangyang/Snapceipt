import Testing
@testable import Snapceipt

@Suite("Segmented")
struct SegmentedTests {
    let opts = [SegmentOption(id: "expense", label: "Expense"),
                SegmentOption(id: "income", label: "Income")]

    @Test func indexOfSelection() {
        #expect(segmentIndex("expense", in: opts) == 0)
        #expect(segmentIndex("income", in: opts) == 1)
    }

    @Test func unknownSelectionFallsBackToZero() {
        #expect(segmentIndex("nope", in: opts) == 0)
    }
}
