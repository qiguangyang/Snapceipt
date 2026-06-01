import Testing
import Foundation
@testable import Snapceipt

@Suite("BAS schedule")
struct BasScheduleTests {
    private func date(_ s: String) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Australia/Sydney"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)!
    }
    @Test("quarterly next-due is the 28th after the current quarter end")
    func quarterly() {
        // 15 Aug 2026 → Q ending 30 Sep 2026 → due 28 Oct 2026
        #expect(BasSchedule.nextDue(.quarterly, on: date("2026-08-15")) == date("2026-10-28"))
        // 5 Jan 2026 → Q ending 31 Dec 2025 already passed → next is Q ending 31 Mar 2026 → due 28 Apr 2026
        #expect(BasSchedule.nextDue(.quarterly, on: date("2026-01-05")) == date("2026-04-28"))
    }
    @Test("monthly next-due is the 21st of the next month")
    func monthly() {
        #expect(BasSchedule.nextDue(.monthly, on: date("2026-08-15")) == date("2026-09-21"))
    }
}
