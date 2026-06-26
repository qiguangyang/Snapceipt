import Testing
import Foundation
@testable import Snapceipt

/// The pure month-filter helpers shared by the Quotes + Invoices date filters.
struct MonthKeyTests {
    @Test("matches: empty key = All time; else prefix-matches the YYYY-MM month")
    func matches() {
        #expect(MonthKey.matches("2026-05-14", MonthKey.allTime) == true)   // "" = all
        #expect(MonthKey.matches("2026-05-14", "2026-05") == true)
        #expect(MonthKey.matches("2026-05-31", "2026-05") == true)
        #expect(MonthKey.matches("2026-06-01", "2026-05") == false)
        #expect(MonthKey.matches("2025-05-14", "2026-05") == false)         // different year
    }

    @Test("available: distinct months present + the current month, newest first")
    func available() {
        let days = ["2026-05-14", "2026-05-02", "2026-03-20", "2026-05-31"]
        let keys = MonthKey.available(days)
        #expect(keys.contains("2026-05"))
        #expect(keys.contains("2026-03"))
        #expect(keys.contains(MonthKey.current))          // current month always selectable
        #expect(Set(keys).count == keys.count)            // distinct
        #expect(keys == keys.sorted(by: >))               // newest first
    }

    @Test("newest: the max month actually present (nil when empty; ignores the inserted current)")
    func newest() {
        #expect(MonthKey.newest(["2026-03-01", "2026-05-09", "2026-01-31"]) == "2026-05")
        #expect(MonthKey.newest([]) == nil)
    }

    @Test("current is a well-formed YYYY-MM key")
    func current() {
        let parts = MonthKey.current.split(separator: "-")
        #expect(MonthKey.current.count == 7)
        #expect(parts.count == 2)
        #expect(parts[0].count == 4 && Int(parts[0]) != nil)   // year
        #expect(parts[1].count == 2 && Int(parts[1]) != nil)   // month
    }
}
