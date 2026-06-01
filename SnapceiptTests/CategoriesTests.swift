import Testing
import SwiftUI
@testable import Snapceipt

@Suite("Categories")
struct CategoriesTests {

    @Test func exactlyNineCategories() {
        #expect(CATS.count == 9)
    }

    @Test func allRawValuesPresent() {
        let keys = Set(CategoryKey.allCases.map(\.rawValue))
        #expect(keys == ["meals", "groceries", "fuel", "software",
                         "office", "home", "health", "travel", "income"])
    }

    @Test func everyKeyHasMeta() {
        for key in CategoryKey.allCases {
            #expect(CATS[key] != nil)
        }
    }

    @Test func mealsMetaMatchesThemeJSX() {
        let meals = CATS[.meals]
        #expect(meals?.label == "Meals & Coffee")
        #expect(meals?.iconName == "cup")
        #expect(meals?.tint == Color(hex: 0xE8602C))
        #expect(meals?.soft == Color(hex: 0xFBEADF))
    }

    @Test func softwareTintMatches() {
        #expect(CATS[.software]?.tint == Color(hex: 0x7B5BD6))
        #expect(CATS[.software]?.iconName == "film")
    }

    @Test func incomeUsesArrowDownIcon() {
        #expect(CATS[.income]?.iconName == "arrowDown")
        #expect(CATS[.income]?.tint == Color(hex: 0x1F9D6B))
    }
}
