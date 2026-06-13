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
    @Test("monthly next-due is the earliest 21st on/after the date")
    func monthly() {
        // Early-month (the bug): 5 Aug is before the 21st, so the imminent 21 Aug is due —
        // NOT the following month's 21 Sep (which the old code wrongly returned).
        #expect(BasSchedule.nextDue(.monthly, on: date("2026-08-05")) == date("2026-08-21"))
        // 15 Aug is also before the 21st → 21 Aug (same month).
        #expect(BasSchedule.nextDue(.monthly, on: date("2026-08-15")) == date("2026-08-21"))
        // On the 21st itself the deadline is still "on/after" → returns it.
        #expect(BasSchedule.nextDue(.monthly, on: date("2026-08-21")) == date("2026-08-21"))
        // Late-month: 25 Aug is after the 21st, so it rolls to the next month's 21 Sep.
        #expect(BasSchedule.nextDue(.monthly, on: date("2026-08-25")) == date("2026-09-21"))
    }

    /// Regression guard for the TaxSettingsView "Next BAS due" display fix.
    /// `nextDue` returns the 28th anchored to Australia/Sydney midnight, so a
    /// statutory BAS date must render as its AU wall-clock day regardless of the
    /// device's UTC offset. The production `fmtBasDue` pins Australia/Sydney; a
    /// device-tz formatter (the old bug) shows it a day early west of Sydney.
    @Test("fmtBasDue reads the AU wall-clock day, independent of the device zone")
    func dueDisplayIsTimeZoneStable() {
        let due = BasSchedule.nextDue(.quarterly, on: date("2026-07-01")) // 28 Jul 2026 AEST

        // Exercise the PRODUCTION formatter directly (not a hand-copied recipe):
        // mis-pinning `fmtBasDue`'s zone west of Sydney makes this read "27 Jul"
        // and turns it red. Paired with the explicit-zone assertions below, this is
        // the literal regression guard for the Sydney pin.
        #expect(fmtBasDue(due) == "28 Jul 2026")

        // Pin down WHY the zone matters: this Date is a Sydney-midnight instant.
        // Rendered in Perth (UTC+8, west of Sydney) it slips to 27 Jul — the exact
        // bug `fmtBasDue`'s Sydney pin prevents; rendered in Sydney it stays 28 Jul.
        func render(in tz: String) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_AU")
            f.timeZone = TimeZone(identifier: tz)
            f.dateFormat = "d MMM yyyy"
            return f.string(from: due)
        }
        #expect(render(in: "Australia/Perth") == "27 Jul 2026")
        #expect(render(in: "Australia/Sydney") == "28 Jul 2026")
    }
}
