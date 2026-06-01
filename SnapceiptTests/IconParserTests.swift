import Testing
import SwiftUI
@testable import Snapceipt

struct IconParserTests {
    @Test func simpleClosedTriangleHasExpectedBounds() {
        let p = Path(svgPath: "M0 0 L10 0 L10 10 Z")
        let b = p.boundingRect
        #expect(abs(b.minX - 0) < 0.001)
        #expect(abs(b.minY - 0) < 0.001)
        #expect(abs(b.maxX - 10) < 0.001)
        #expect(abs(b.maxY - 10) < 0.001)
    }

    @Test func relativeAndVHCommandsAdvance() {
        // M then implicit-lineto, relative l, V, H — must not collapse to a point.
        let p = Path(svgPath: "M3 10.6 12 4l9 6.6M5.5 9.2V19H10")
        #expect(!p.isEmpty)
        #expect(p.boundingRect.width > 1)
        #expect(p.boundingRect.height > 1)
    }

    @Test func everyCoreGlyphParsesWithinGrid() {
        for (name, d) in Icons.paths {
            let p = Path(svgPath: d)
            #expect(!p.isEmpty, "\(name) parsed empty")
            let b = p.boundingRect
            // Allow a small epsilon for stroke geometry; icons live on a 0...24 grid.
            #expect(b.minX >= -0.5 && b.minY >= -0.5, "\(name) out of grid (min)")
            #expect(b.maxX <= 24.5 && b.maxY <= 24.5, "\(name) out of grid (max)")
        }
    }

    @Test func arcCommandProducesCurve() {
        // 'a1 1 0 0 0 1 1' (relative arc) used by home/user/bell/camera etc.
        let p = Path(svgPath: "M5 9a1 1 0 0 0 1 1")
        #expect(!p.isEmpty)
        #expect(p.boundingRect.width > 0.5)
    }
}
