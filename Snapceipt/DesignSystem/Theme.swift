import SwiftUI

// MARK: - Hex Color

extension Color {
    /// Builds an opaque sRGB color from a 24-bit RGB hex value, e.g. `Color(hex: 0xE8602C)`.
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }
}

// MARK: - Palette (design tokens, screens.md line 100)

enum Palette {
    static let cream = Color(hex: 0xFBF6F0)
    static let paper = Color(hex: 0xFFFFFF)
    static let paper2 = Color(hex: 0xF6EEE4)
    static let ink = Color(hex: 0x211C18)
    static let ink2 = Color(hex: 0x6B6258)
    static let ink3 = Color(hex: 0xA99F93)
    static let line = Color(hex: 0xECE3D8)
    static let line2 = Color(hex: 0xF3EBE1)
    static let income = Color(hex: 0x1F9D6B)
    static let incomeSoft = Color(hex: 0xDEF3E9)
    static let alert = Color(hex: 0xD6452B)
}

// MARK: - Radii

enum Radius {
    static let card: CGFloat = 22
    static let inner: CGFloat = 16
    static let chip: CGFloat = 12
}

// MARK: - Shadows

/// `sh-card`: 0 1px 2px rgba(33,28,24,.04), 0 10px 26px -16px rgba(33,28,24,.14).
/// SwiftUI radius = CSS blur / 2; the -16px spread on the second layer is approximated
/// by halving its blur (SwiftUI has no spread parameter).
private struct CardShadow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .shadow(color: Palette.ink.opacity(0.04), radius: 1, x: 0, y: 1)
            .shadow(color: Palette.ink.opacity(0.14), radius: 5, x: 0, y: 10)
    }
}

/// `sh-pop`: 0 8px 24px -8px rgba(33,28,24,.22), 0 2px 6px rgba(33,28,24,.08).
private struct PopShadow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .shadow(color: Palette.ink.opacity(0.22), radius: 8, x: 0, y: 8)
            .shadow(color: Palette.ink.opacity(0.08), radius: 3, x: 0, y: 2)
    }
}

extension View {
    /// Applies the `sh-card` two-layer shadow.
    func cardShadow() -> some View { modifier(CardShadow()) }
    /// Applies the `sh-pop` two-layer shadow.
    func popShadow() -> some View { modifier(PopShadow()) }
}

#Preview("Theme tokens") {
    VStack(spacing: 16) {
        RoundedRectangle(cornerRadius: Radius.card)
            .fill(Palette.paper)
            .frame(width: 220, height: 96)
            .overlay(Text("cardShadow()").foregroundStyle(Palette.ink))
            .cardShadow()
        RoundedRectangle(cornerRadius: Radius.inner)
            .fill(Palette.cream)
            .frame(width: 220, height: 72)
            .overlay(Text("popShadow()").foregroundStyle(Palette.ink2))
            .popShadow()
        HStack(spacing: 10) {
            Circle().fill(AccentPalette.personal.base).frame(width: 28, height: 28)
            Circle().fill(AccentPalette.personal.soft).frame(width: 28, height: 28)
            Circle().fill(AccentPalette.business.base).frame(width: 28, height: 28)
        }
    }
    .padding(40)
    .background(Palette.cream)
}
