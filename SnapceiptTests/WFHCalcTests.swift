import Testing
import Foundation
@testable import Snapceipt

@Suite("WFHCalc")
struct WFHCalcTests {

    @Test("per-entry claim rounds minutes/60 * rate")
    func entryClaim() {
        // 90 minutes @ 70c/hr = 1.5h * 70 = 105 cents
        #expect(WFHCalc.claimCents(minutes: 90, rateCentsPerHour: 70) == 105)
        // 25 minutes @ 70c/hr = 0.41666h * 70 = 29.16.. -> 29
        #expect(WFHCalc.claimCents(minutes: 25, rateCentsPerHour: 70) == 29)
        #expect(WFHCalc.claimCents(minutes: 0, rateCentsPerHour: 70) == 0)
    }

    @Test("FY hero aggregates minutes + claim over the FY logs")
    func heroAggregation() {
        let logs = [
            WFHCalc.Entry(logDate: "2025-07-02", minutes: 480, claimCents: 560),  // in FY25-26
            WFHCalc.Entry(logDate: "2025-08-10", minutes: 300, claimCents: 350),  // in FY25-26
            WFHCalc.Entry(logDate: "2025-06-30", minutes: 480, claimCents: 560),  // PREV FY -> excluded
        ]
        let h = WFHCalc.hero(entries: logs, fyStartYear: 2025, startMonth: 7)
        #expect(h.totalMinutes == 780)
        #expect(h.claimCents == 910)
        #expect(h.daysLogged == 2)
        // avg/day hours = (780/60) / 2 = 6.5
        #expect(abs(h.avgHoursPerDay - 6.5) < 0.0001)
    }

    @Test("empty FY hero is all-zero with avg 0")
    func heroEmpty() {
        let h = WFHCalc.hero(entries: [], fyStartYear: 2025, startMonth: 7)
        #expect(h.totalMinutes == 0)
        #expect(h.claimCents == 0)
        #expect(h.daysLogged == 0)
        #expect(h.avgHoursPerDay == 0)
    }

    @Test("this-week buckets minutes into Mon..Sun for the week containing `today`")
    func thisWeek() {
        // Week of Mon 2025-09-01 .. Sun 2025-09-07.
        let today = isoUTC("2025-09-03")  // Wednesday
        let entries = [
            WFHCalc.Entry(logDate: "2025-09-01", minutes: 360, claimCents: 420),  // Mon -> idx 0
            WFHCalc.Entry(logDate: "2025-09-03", minutes: 480, claimCents: 560),  // Wed -> idx 2
            WFHCalc.Entry(logDate: "2025-09-07", minutes: 120, claimCents: 140),  // Sun -> idx 6
            WFHCalc.Entry(logDate: "2025-08-31", minutes: 999, claimCents: 0),    // prev week -> excluded
        ]
        let week = WFHCalc.thisWeekMinutes(entries: entries, today: today)
        #expect(week == [360, 0, 480, 0, 0, 0, 120])
    }

    /// UTC date helper for the test.
    private func isoUTC(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)!
    }
}
