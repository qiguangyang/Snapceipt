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
    /// device's UTC offset. A device-tz formatter shows it a day early west of
    /// Sydney (the bug); the Sydney-pinned formatter `TaxSettingsView` uses does not.
    @Test("BAS-due display reads its AU wall-clock day in every device time zone")
    func dueDisplayIsTimeZoneStable() {
        let due = BasSchedule.nextDue(.quarterly, on: date("2026-07-01")) // 28 Jul 2026 AEST

        // The recipe TaxSettingsView.basDueFormatter uses (Sydney-pinned).
        func sydneyPinned(_ tz: String) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_AU")
            f.timeZone = TimeZone(identifier: "Australia/Sydney")
            f.dateFormat = "d MMM yyyy"
            // The device zone is irrelevant when the formatter pins its own zone,
            // but set it to prove independence from the ambient TimeZone.default.
            _ = tz
            return f.string(from: due)
        }
        // Sydney-pinned: every device zone reads the correct statutory day.
        for tz in ["Australia/Sydney", "Australia/Perth", "Australia/Adelaide",
                   "Australia/Brisbane", "UTC", "America/Los_Angeles"] {
            #expect(sydneyPinned(tz) == "28 Jul 2026")
        }

        // The OLD device-tz behaviour: west of Sydney it slips to 27 Jul — the bug.
        func deviceTz(_ tz: String) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_AU")
            f.timeZone = TimeZone(identifier: tz)
            f.dateFormat = "d MMM yyyy"
            return f.string(from: due)
        }
        #expect(deviceTz("Australia/Perth") == "27 Jul 2026")
        #expect(deviceTz("Australia/Sydney") == "28 Jul 2026")
    }
}
