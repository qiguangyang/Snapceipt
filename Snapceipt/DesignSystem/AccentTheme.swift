import SwiftUI

/// Accent triad driving every `--accent / --accent-soft / --accent-deep` surface.
/// The active profile supplies this at runtime; default = personal terracotta.
struct AccentPalette: Equatable {
    let base: Color
    let soft: Color
    let deep: Color

    /// Personal terracotta — AP_ACCENTS[0]: #E8602C / #FDEBE0 / #C2461A.
    static let personal = AccentPalette(
        base: Color(hex: 0xE8602C),
        soft: Color(hex: 0xFDEBE0),
        deep: Color(hex: 0xC2461A)
    )

    /// Business teal — AP_ACCENTS[1]: #0E7C72 / #DCF0ED / #0A5950.
    static let business = AccentPalette(
        base: Color(hex: 0x0E7C72),
        soft: Color(hex: 0xDCF0ED),
        deep: Color(hex: 0x0A5950)
    )

    /// Builds an accent from a stored profile palette `[base, soft, deep]` (24-bit RGB hexes).
    /// Returns `nil` for any array that is not exactly three elements.
    init?(hexes: [UInt32]) {
        guard hexes.count == 3 else { return nil }
        self.base = Color(hex: hexes[0])
        self.soft = Color(hex: hexes[1])
        self.deep = Color(hex: hexes[2])
    }

    /// Memberwise initializer (the failable one above shadows the synthesized init).
    init(base: Color, soft: Color, deep: Color) {
        self.base = base
        self.soft = soft
        self.deep = deep
    }
}

// MARK: - Environment

private struct AccentEnvironmentKey: EnvironmentKey {
    static let defaultValue: AccentPalette = .personal
}

extension EnvironmentValues {
    /// `@Environment(\.accent) var accent` — the active profile's accent triad.
    var accent: AccentPalette {
        get { self[AccentEnvironmentKey.self] }
        set { self[AccentEnvironmentKey.self] = newValue }
    }
}
