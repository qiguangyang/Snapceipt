import Foundation

/// The 9 canonical category keys (matches theme.jsx CATS + the /extract
/// contract; there is no `other` — the extractor always picks one of these).
///
/// PURE (Foundation only, no SwiftUI/SwiftData) so it compiles into BOTH the
/// app and the Share Extension — the on-device extraction code in
/// `Features/Capture/Scanner/*` references it. The SwiftUI display metadata
/// (`CATS`, `CategoryMeta`) lives in `Categories.swift`, which is app-only.
enum CategoryKey: String, CaseIterable, Codable, Sendable {
    case meals
    case groceries
    case fuel
    case software
    case office
    case home
    case health
    case travel
    case income
}
