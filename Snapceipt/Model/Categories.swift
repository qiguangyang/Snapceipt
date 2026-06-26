import SwiftUI

// `CategoryKey` lives in its own pure (Foundation-only) file `CategoryKey.swift`
// so it can compile into the Share Extension alongside the on-device extraction
// code. The SwiftUI-dependent display metadata below stays app-only.

/// Display metadata for a category: human label, line-icon name (theme.jsx
/// ICONS key), and the tint/soft color pair for IconCircle + chips.
struct CategoryMeta: Equatable {
    let label: String
    let iconName: String
    let tint: Color
    let soft: Color
}

/// Category metadata table, mirroring theme.jsx `CATS` exactly.
let CATS: [CategoryKey: CategoryMeta] = [
    .meals:     CategoryMeta(label: "Meals & Coffee",   iconName: "cup",       tint: Color(hex: 0xE8602C), soft: Color(hex: 0xFBEADF)),
    .groceries: CategoryMeta(label: "Groceries",        iconName: "cart",      tint: Color(hex: 0xC99A22), soft: Color(hex: 0xF6EECE)),
    .fuel:      CategoryMeta(label: "Fuel & Transport", iconName: "fuel",      tint: Color(hex: 0x2F6FB0), soft: Color(hex: 0xE2ECF6)),
    .software:  CategoryMeta(label: "Software & Subs",  iconName: "film",      tint: Color(hex: 0x7B5BD6), soft: Color(hex: 0xEBE5F8)),
    .office:    CategoryMeta(label: "Office & Supplies",iconName: "building",  tint: Color(hex: 0x0E7C72), soft: Color(hex: 0xDCF0ED)),
    .home:      CategoryMeta(label: "Home & Utilities", iconName: "home",      tint: Color(hex: 0xB0568F), soft: Color(hex: 0xF4E4EF)),
    .health:    CategoryMeta(label: "Health",           iconName: "heart",     tint: Color(hex: 0xD6452B), soft: Color(hex: 0xF8E2DD)),
    .travel:    CategoryMeta(label: "Travel & Stays",   iconName: "pin",       tint: Color(hex: 0x1F9D6B), soft: Color(hex: 0xDEF3E9)),
    .income:    CategoryMeta(label: "Income",           iconName: "arrowDown", tint: Color(hex: 0x1F9D6B), soft: Color(hex: 0xDEF3E9)),
]
