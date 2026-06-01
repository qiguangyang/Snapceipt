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
    @Test("quarterly next-due is the earliest ATO BAS deadline on/after the date")
    func quarterly() {
        // 15 Aug 2026 → next deadline is 28 Oct 2026 (Q1 Jul–Sep).
        #expect(BasSchedule.nextDue(.quarterly, on: date("2026-08-15")) == date("2026-10-28"))
        // In-window (the bug): on 10 Oct the 28 Oct deadline is still in the future,
        // so it must be returned — not the following quarter's.
        #expect(BasSchedule.nextDue(.quarterly, on: date("2026-10-10")) == date("2026-10-28"))
        // Last day of the lodge window before the due — still the same 28 Oct deadline.
        #expect(BasSchedule.nextDue(.quarterly, on: date("2026-10-27")) == date("2026-10-28"))
        // On the due date itself the deadline is still "on/after" → returns it.
        #expect(BasSchedule.nextDue(.quarterly, on: date("2026-10-28")) == date("2026-10-28"))
        // Just after the 28 Oct due → advances to the next deadline.
        #expect(BasSchedule.nextDue(.quarterly, on: date("2026-10-29")) == date("2027-02-28"))
        // Oct–Dec quarter is due 28 FEB of the following year (extra month over Christmas).
        #expect(BasSchedule.nextDue(.quarterly, on: date("2026-12-15")) == date("2027-02-28"))
        // 5 Jan 2026 → the 28 Dec-quarter deadline is 28 Feb 2026; still future → returns it.
        #expect(BasSchedule.nextDue(.quarterly, on: date("2026-01-05")) == date("2026-02-28"))
    }
    @Test("monthly next-due is the 21st of the next month")
    func monthly() {
        #expect(BasSchedule.nextDue(.monthly, on: date("2026-08-15")) == date("2026-09-21"))
    }
}
