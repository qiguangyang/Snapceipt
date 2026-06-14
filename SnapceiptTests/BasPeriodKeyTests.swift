import Testing
import Foundation
@testable import Snapceipt

@Suite("BasPeriodKey")
struct BasPeriodKeyTests {
    private func utc(_ s: String) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)!
    }

    @Test("quarterly key is <fyStartYear>Q<n>")
    func quarterly() {
        // Apr–Jun 2026 = Q4 of FY2025-26 → "2025Q4".
        let w = Period.quarter.window(now: utc("2026-05-15"), startMonth: 7)
        #expect(BasPeriodKey.make(window: w, basPeriod: .quarterly, startMonth: 7) == "2025Q4")
        // Jul–Sep 2025 = Q1 of FY2025-26 → "2025Q1".
        let w2 = Period.quarter.window(now: utc("2025-08-10"), startMonth: 7)
        #expect(BasPeriodKey.make(window: w2, basPeriod: .quarterly, startMonth: 7) == "2025Q1")
    }

    @Test("monthly key is <calendarYear>M<mm>")
    func monthly() {
        let w = Period.month.window(now: utc("2026-04-09"), startMonth: 7)
        #expect(BasPeriodKey.make(window: w, basPeriod: .monthly, startMonth: 7) == "2026M04")
        let w2 = Period.month.window(now: utc("2026-12-31"), startMonth: 7)
        #expect(BasPeriodKey.make(window: w2, basPeriod: .monthly, startMonth: 7) == "2026M12")
    }
}
