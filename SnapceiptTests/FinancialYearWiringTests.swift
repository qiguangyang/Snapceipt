import Testing
import Foundation
@testable import Snapceipt

@Suite("FinancialYear wiring")
struct FinancialYearWiringTests {
    private func date(_ s: String) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)!
    }
    @Test("a non-July FY start changes the computed financial year")
    func nonJuly() {
        // For a March date the two FY starts diverge:
        // FY start = 7 (July): 2026-03-01 is BEFORE July 2026 → FY starting 2025 ("FY2025-26").
        // FY start = 1 (Jan):  2026-03-01 is on/after Jan 2026 → FY starting 2026 ("FY2026-27").
        let july = FinancialYear.of(date("2026-03-01"), startMonth: 7)
        let jan = FinancialYear.of(date("2026-03-01"), startMonth: 1)
        #expect(july.startYear != jan.startYear || july.label != jan.label)
    }
}
