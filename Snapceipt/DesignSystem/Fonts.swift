import SwiftUI

/// Bundled font family names. These exact strings are what `Font.custom` looks up;
/// they must match the families registered via Info.plist `UIAppFonts` (Task 1).
///
/// The nine bundled TTFs are static instances sharing two *typographic* families
/// (name ID 16): "Schibsted Grotesk" and "Hanken Grotesk". `Font.custom(_:size:)`
/// resolves by typographic family and then `.weight(_:)` selects the matching member.
enum Typeface {
    static let display = "Schibsted Grotesk"   // numbers, headings, initials
    static let ui = "Hanken Grotesk"           // all other UI text
}

extension Font {
    /// Schibsted Grotesk at a point size + weight (default bold, matching the design).
    static func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .custom(Typeface.display, size: size).weight(weight)
    }

    /// Hanken Grotesk at a point size + weight (default regular).
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(Typeface.ui, size: size).weight(weight)
    }
}

/// Applies the design's numeric treatment: display face, monospaced (tabular) digits,
/// and ~-0.01em tracking — used for every amount/figure so columns align.
private struct NumericText: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    func body(content: Content) -> some View {
        content
            .font(.display(size, weight).monospacedDigit())
            .tracking(-0.01 * size)   // -0.01em, expressed in points relative to size
    }
}

extension View {
    /// Render numeric text in the display face with tabular digits + tight tracking.
    func numeric(_ size: CGFloat, _ weight: Font.Weight = .bold) -> some View {
        modifier(NumericText(size: size, weight: weight))
    }
}

#if DEBUG
#Preview("Typography") {
    VStack(alignment: .leading, spacing: 12) {
        Text("Snapceipt").font(.display(28, .bold))
        Text("Snap it. Sort it. Sorted.").font(.ui(15, .medium))
        Text("−$42.50").numeric(34)
        Text("$4,200").numeric(18, .semibold)
    }
    .padding()
    .background(Palette.cream)   // from Theme.swift (Task 2)
}
#endif
