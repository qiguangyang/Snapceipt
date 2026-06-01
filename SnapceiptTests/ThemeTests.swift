import Testing
import SwiftUI
import UIKit
@testable import Snapceipt

@Suite("Theme")
struct ThemeTests {

    /// Reads 0...1 RGBA components from a SwiftUI Color via UIColor (iOS 17 supported path).
    private func rgba(_ color: Color) -> (r: Double, g: Double, b: Double, a: Double) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b), Double(a))
    }

    @Test("Color(hex:) decodes RGB channels and opaque alpha")
    func hexDecodesTerracotta() {
        let c = rgba(Color(hex: 0xE8602C))
        #expect(abs(c.r - 232.0 / 255.0) < 0.005)
        #expect(abs(c.g - 96.0 / 255.0) < 0.005)
        #expect(abs(c.b - 44.0 / 255.0) < 0.005)
        #expect(abs(c.a - 1.0) < 0.001)
    }

    @Test("Color(hex:) decodes pure black and pure white")
    func hexDecodesBlackAndWhite() {
        let black = rgba(Color(hex: 0x000000))
        #expect(black.r < 0.005 && black.g < 0.005 && black.b < 0.005)
        #expect(abs(black.a - 1.0) < 0.001)

        let white = rgba(Color(hex: 0xFFFFFF))
        #expect(white.r > 0.995 && white.g > 0.995 && white.b > 0.995)
    }

    @Test("Default accent base is terracotta #E8602C")
    func defaultAccentBaseIsTerracotta() {
        let base = rgba(AccentPalette.personal.base)
        let expected = rgba(Color(hex: 0xE8602C))
        #expect(abs(base.r - expected.r) < 0.005)
        #expect(abs(base.g - expected.g) < 0.005)
        #expect(abs(base.b - expected.b) < 0.005)
    }

    @Test("AccentPalette(hexes:) maps base/soft/deep in order")
    func accentFromHexesMapsInOrder() {
        // Business teal AP_ACCENTS[4]: base #0E7C72, soft #DCF0ED, deep #0A5950
        let teal = AccentPalette(hexes: [0x0E7C72, 0xDCF0ED, 0x0A5950])
        #expect(teal != nil)
        let base = rgba(teal!.base)
        let expected = rgba(Color(hex: 0x0E7C72))
        #expect(abs(base.r - expected.r) < 0.005)
        #expect(abs(base.g - expected.g) < 0.005)
        #expect(abs(base.b - expected.b) < 0.005)
        // Wrong-length input is rejected.
        #expect(AccentPalette(hexes: [0x0E7C72, 0xDCF0ED]) == nil)
    }
}
