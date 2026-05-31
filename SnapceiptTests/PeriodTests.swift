import Testing
import Foundation
@testable import Snapceipt

@Suite("Period")
struct PeriodTests {
    /// UTC date helper (mirrors FinancialYear's parser).
    private func iso(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)!
    }
    /// Read a window's bounds back as ISO strings for assertions.
    private func isoOut(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    @Test("month window is the calendar month of now, [start, nextMonth)")
    func monthWindow() {
        let w = Period.month.window(now: iso("2026-06-15"), startMonth: 7)
        #expect(isoOut(w.start) == "2026-06-01")
        #expect(isoOut(w.end) == "2026-07-01")
        #expect(w.label == "June 2026")
    }

    @Test("quarter window maps to AU FY quarters")
    func quarterWindows() {
        // June -> Q4 Apr-Jun
        let q4 = Period.quarter.window(now: iso("2026-06-15"), startMonth: 7)
        #expect(isoOut(q4.start) == "2026-04-01")
        #expect(isoOut(q4.end) == "2026-07-01")
        #expect(q4.label == "Apr–Jun 2026")
        // July -> Q1 Jul-Sep
        let q1 = Period.quarter.window(now: iso("2025-07-10"), startMonth: 7)
        #expect(isoOut(q1.start) == "2025-07-01")
        #expect(isoOut(q1.end) == "2025-10-01")
        #expect(q1.label == "Jul–Sep 2025")
        // January -> Q3 Jan-Mar
        let q3 = Period.quarter.window(now: iso("2026-01-20"), startMonth: 7)
        #expect(isoOut(q3.start) == "2026-01-01")
        #expect(isoOut(q3.end) == "2026-04-01")
        #expect(q3.label == "Jan–Mar 2026")
    }

    @Test("fy window reuses FinancialYear.of and its label")
    func fyWindow() {
        let w = Period.fy.window(now: iso("2026-06-30"), startMonth: 7)
        #expect(isoOut(w.start) == "2025-07-01")
        #expect(isoOut(w.end) == "2026-07-01")
        #expect(w.label == "FY2025-26")
        // 1 Jul flips to the next FY.
        let next = Period.fy.window(now: iso("2026-07-01"), startMonth: 7)
        #expect(next.label == "FY2026-27")
    }

    @Test("headline caption is period-appropriate")
    func headlineCaption() {
        #expect(Period.month.headline(now: iso("2026-06-15"), startMonth: 7) == "This month")
        #expect(Period.quarter.headline(now: iso("2026-06-15"), startMonth: 7) == "This quarter")
        #expect(Period.fy.headline(now: iso("2026-06-15"), startMonth: 7) == "FY2025-26")
    }
}
