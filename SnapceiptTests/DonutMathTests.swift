import Testing
import SwiftUI
@testable import Snapceipt

@Suite("Donut segment math")
struct DonutMathTests {

    @Test("radius and circumference match (size - thickness)/2")
    func radiusCircumference() {
        let layout = DonutMath.layout(segments: [], size: 160, thickness: 22)
        #expect(layout.radius == CGFloat(160 - 22) / 2)        // 69
        #expect(abs(layout.circumference - 2 * .pi * 69) < 0.0001)
    }

    @Test("two equal segments split the ring in half, each minus the 3pt gap")
    func equalSegments() {
        let segs = [
            DonutSegment(id: "a", value: 50, tint: .red),
            DonutSegment(id: "b", value: 50, tint: .blue),
        ]
        let layout = DonutMath.layout(segments: segs, size: 160, thickness: 22)
        let half = layout.circumference / 2
        #expect(layout.arcs.count == 2)
        // dash length = (value/total)*C - 3
        #expect(abs(layout.arcs[0].dashLength - (half - 3)) < 0.0001)
        #expect(abs(layout.arcs[1].dashLength - (half - 3)) < 0.0001)
    }

    @Test("offsets accumulate by un-gapped segment length")
    func accumulatingOffsets() {
        let segs = [
            DonutSegment(id: "a", value: 25, tint: .red),
            DonutSegment(id: "b", value: 75, tint: .blue),
        ]
        let layout = DonutMath.layout(segments: segs, size: 160, thickness: 22)
        let C = layout.circumference
        #expect(abs(layout.arcs[0].dashOffset - 0) < 0.0001)
        // second arc starts after the first's full (un-gapped) length = 0.25*C
        #expect(abs(layout.arcs[1].dashOffset - (0.25 * C)) < 0.0001)
    }

    @Test("fractions sum to 1 over total")
    func fractionsSumToOne() {
        let segs = [
            DonutSegment(id: "a", value: 10, tint: .red),
            DonutSegment(id: "b", value: 30, tint: .blue),
            DonutSegment(id: "c", value: 60, tint: .green),
        ]
        let layout = DonutMath.layout(segments: segs, size: 140, thickness: 20)
        let sum = layout.arcs.reduce(0) { $0 + $1.fraction }
        #expect(abs(sum - 1) < 0.0001)
    }

    @Test("empty segments produce no arcs and no NaN")
    func emptyGuard() {
        let layout = DonutMath.layout(segments: [], size: 140, thickness: 20)
        #expect(layout.arcs.isEmpty)
        #expect(!layout.circumference.isNaN)
    }

    @Test("dash length never goes negative for tiny slices")
    func tinySliceClampsToZero() {
        let segs = [
            DonutSegment(id: "big", value: 1000, tint: .red),
            DonutSegment(id: "tiny", value: 1, tint: .blue),
        ]
        let layout = DonutMath.layout(segments: segs, size: 160, thickness: 22)
        #expect(layout.arcs[1].dashLength >= 0)
    }
}
