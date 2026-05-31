import Testing
import Foundation
@testable import Snapceipt

@Suite("FinancialYear")
struct FinancialYearTests {

    /// UTC date from a "yyyy-MM-dd" string (matches the app's ISO date handling).
    private func d(_ iso: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: iso)!
    }

    @Test("1 Jul 2025 starts FY2025-26")
    func startBoundary() {
        let fy = FinancialYear.of(d("2025-07-01"), startMonth: 7)
        #expect(fy.startYear == 2025)
        #expect(fy.label == "FY2025-26")
    }

    @Test("30 Jun 2025 belongs to the PREVIOUS FY2024-25")
    func endBoundary() {
        let fy = FinancialYear.of(d("2025-06-30"), startMonth: 7)
        #expect(fy.startYear == 2024)
        #expect(fy.label == "FY2024-25")
    }

    @Test("a mid-year date sits in the right FY")
    func midYear() {
        let fy = FinancialYear.of(d("2026-03-15"), startMonth: 7)
        #expect(fy.startYear == 2025)
        #expect(fy.label == "FY2025-26")
    }

    @Test("label wraps the century at FY1999-00")
    func centuryWrap() {
        let fy = FinancialYear.of(d("1999-09-01"), startMonth: 7)
        #expect(fy.startYear == 1999)
        #expect(fy.label == "FY1999-00")
    }

    @Test("isIn includes 1 Jul, excludes the next 1 Jul")
    func membership() {
        #expect(FinancialYear.isIn(d("2025-07-01"), fyStartYear: 2025, startMonth: 7) == true)
        #expect(FinancialYear.isIn(d("2026-06-30"), fyStartYear: 2025, startMonth: 7) == true)
        #expect(FinancialYear.isIn(d("2026-07-01"), fyStartYear: 2025, startMonth: 7) == false)
        #expect(FinancialYear.isIn(d("2025-06-30"), fyStartYear: 2025, startMonth: 7) == false)
    }

    @Test("isInString accepts a 'yyyy-MM-dd' trip date")
    func membershipString() {
        #expect(FinancialYear.isIn("2025-08-12", fyStartYear: 2025, startMonth: 7) == true)
        #expect(FinancialYear.isIn("2025-06-30", fyStartYear: 2025, startMonth: 7) == false)
        #expect(FinancialYear.isIn("not-a-date", fyStartYear: 2025, startMonth: 7) == false)
    }
}
